// Pure logic for the sms-dispatch Edge Function, kept free of Deno / Supabase imports so it can be
// unit-tested with plain Node (tests/sms_dispatch_tests.mjs). index.ts wires it to the real
// database and fetch.
//
// It only ever SENDS rows that already exist in sms_messages -- rows are created exclusively by
// rota_sms_queue / sms_queue_test, i.e. a superadmin pressing Send. Nothing here creates a text.
//
// Gateway: SMS Gateway for Android (sms-gate.app), cloud mode, on the clinic's Android phone.
// The gateway message id is set to OUR sms_messages.id, and the gateway answers 409 for an id it
// already has -- so re-sending an interrupted hand-over can never produce a second text.

export type SmsRow = {
  id: string;
  to_number: string;
  body: string;
  kind: string;
  attempts: number;
  gateway_id: string | null;
};

export type RpcResult = { data: unknown; error: { message: string } | null };
export type Rpc = (fn: string, args: Record<string, unknown>) => Promise<RpcResult>;
export type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;

export type Config = {
  mode: string;          // 'live' sends; anything else (default 'dryrun') never contacts the gateway
  allowlist: string[];   // if non-empty, only these numbers are really sent (staging safety)
  user: string;
  pass: string;
  baseUrl: string;
  ttlSeconds: number;    // a text the phone can't send within this time expires instead of arriving late
  timeoutMs: number;
};

export type Summary = {
  mode: string;
  claimed: number;
  accepted: number;
  dryRun: number;
  retry: number;
  failed: number;
  statusChecked: number;
};

export function normaliseUkMobile(s: string): string | null {
  const d = String(s || "").replace(/[^0-9]/g, "");
  if (/^07[0-9]{9}$/.test(d)) return "+44" + d.slice(1);
  if (/^447[0-9]{9}$/.test(d)) return "+" + d;
  if (/^00447[0-9]{9}$/.test(d)) return "+" + d.slice(2);
  return null;
}

export function readConfig(get: (k: string) => string | undefined): Config {
  const allow = String(get("SMS_ALLOWLIST") || "")
    .split(/[,;]+/)   // not on spaces: "07700 900001" is one number
    .map(normaliseUkMobile)
    .filter((x): x is string => !!x);
  const ttl = Number(get("SMS_TTL_SECONDS") || "");
  return {
    mode: String(get("SMS_MODE") || "dryrun").trim().toLowerCase(),
    allowlist: allow,
    user: String(get("SMS_GATEWAY_USER") || ""),
    pass: String(get("SMS_GATEWAY_PASS") || ""),
    baseUrl: String(get("SMS_GATEWAY_URL") || "https://api.sms-gate.app/3rdparty/v1").replace(/\/+$/, ""),
    ttlSeconds: Number.isFinite(ttl) && ttl >= 60 ? Math.floor(ttl) : 12 * 60 * 60,
    timeoutMs: 15000,
  };
}

// Constant-time comparison for the dispatch secret.
export function secretsMatch(given: string, expected: string): boolean {
  if (!expected) return false;
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < b.length; i++) diff |= (a[i] ?? 0) ^ b[i];
  return diff === 0;
}

function basicAuth(user: string, pass: string): string {
  let bin = "";
  for (const b of new TextEncoder().encode(user + ":" + pass)) bin += String.fromCharCode(b);
  return "Basic " + btoa(bin);
}

async function withTimeout(fetchFn: FetchFn, url: string, init: RequestInit, ms: number): Promise<Response> {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  try {
    return await fetchFn(url, { ...init, signal: ctl.signal });
  } finally {
    clearTimeout(t);
  }
}

type Outcome = { outcome: "accepted" | "dry_run" | "retry" | "failed"; gatewayId: string | null; error: string | null };

export async function sendOne(row: SmsRow, cfg: Config, fetchFn: FetchFn): Promise<Outcome> {
  if (cfg.mode !== "live") {
    return { outcome: "dry_run", gatewayId: null, error: `Dry run - not sent (SMS_MODE=${cfg.mode})` };
  }
  if (cfg.allowlist.length && !cfg.allowlist.includes(row.to_number)) {
    return { outcome: "dry_run", gatewayId: null, error: "Dry run - number not on the allow-list" };
  }
  if (!cfg.user || !cfg.pass) {
    return { outcome: "failed", gatewayId: null, error: "Phone gateway username/password are not set up" };
  }
  let res: Response;
  try {
    res = await withTimeout(fetchFn, `${cfg.baseUrl}/messages`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: basicAuth(cfg.user, cfg.pass) },
      body: JSON.stringify({
        id: row.id,
        textMessage: { text: row.body },
        phoneNumbers: [row.to_number],
        withDeliveryReport: true,
        ttl: cfg.ttlSeconds,
      }),
    }, cfg.timeoutMs);
  } catch (e) {
    return { outcome: "retry", gatewayId: null, error: "Phone gateway unreachable: " + String((e as Error)?.message || e).slice(0, 200) };
  }
  const text = await res.text().catch(() => "");
  if (res.status === 200 || res.status === 201 || res.status === 202) {
    let id = row.id;
    try { const j = JSON.parse(text); if (j && typeof j.id === "string" && j.id) id = j.id; } catch { /* keep our id */ }
    return { outcome: "accepted", gatewayId: id, error: null };
  }
  if (res.status === 409) {
    // The gateway already has a text with this id: an earlier attempt got through.
    return { outcome: "accepted", gatewayId: row.id, error: null };
  }
  if (res.status === 400 || res.status === 401 || res.status === 403 || res.status === 422) {
    return { outcome: "failed", gatewayId: null, error: `Phone gateway refused the text (${res.status}): ${text.slice(0, 200)}` };
  }
  return { outcome: "retry", gatewayId: null, error: `Phone gateway error (${res.status}): ${text.slice(0, 200)}` };
}

export async function runDispatch(rpc: Rpc, fetchFn: FetchFn, cfg: Config): Promise<Summary> {
  const summary: Summary = { mode: cfg.mode, claimed: 0, accepted: 0, dryRun: 0, retry: 0, failed: 0, statusChecked: 0 };

  const claimed = await rpc("sms_claim_due", { p_limit: 20 });
  if (claimed.error) throw new Error("sms_claim_due: " + claimed.error.message);
  const rows = (claimed.data as SmsRow[]) || [];
  summary.claimed = rows.length;

  for (const row of rows) {
    const r = await sendOne(row, cfg, fetchFn);
    const marked = await rpc("sms_mark_result", {
      p_id: row.id, p_outcome: r.outcome, p_gateway_id: r.gatewayId, p_error: r.error,
    });
    if (marked.error) throw new Error("sms_mark_result: " + marked.error.message);
    if (r.outcome === "accepted") summary.accepted++;
    else if (r.outcome === "dry_run") summary.dryRun++;
    else if (r.outcome === "retry") summary.retry++;
    else summary.failed++;
  }

  // Ask the gateway what happened to texts handed over earlier (pending on the phone, sent,
  // delivered, failed, expired). Only in live mode, where texts really went to the gateway.
  if (cfg.mode === "live" && cfg.user && cfg.pass) {
    const checks = await rpc("sms_due_status_checks", { p_limit: 20 });
    if (checks.error) throw new Error("sms_due_status_checks: " + checks.error.message);
    for (const row of ((checks.data as SmsRow[]) || [])) {
      if (!row.gateway_id) continue;
      try {
        const res = await withTimeout(fetchFn, `${cfg.baseUrl}/messages/${encodeURIComponent(row.gateway_id)}`, {
          method: "GET", headers: { Authorization: basicAuth(cfg.user, cfg.pass) },
        }, cfg.timeoutMs);
        if (res.status !== 200) continue;
        const j = await res.json();
        const state = String(j?.state || "").toLowerCase();
        if (!state) continue;
        const recipErr = Array.isArray(j?.recipients) ? (j.recipients.find((x: { error?: string }) => x && x.error)?.error || null) : null;
        const ev = await rpc("sms_gateway_event", { p_gateway_id: row.gateway_id, p_state: state, p_error: recipErr });
        if (ev.error) throw new Error("sms_gateway_event: " + ev.error.message);
        summary.statusChecked++;
      } catch (e) {
        if (String((e as Error)?.message || "").startsWith("sms_gateway_event")) throw e;
        // gateway unreachable for a status check: try again next minute
      }
    }
  }
  return summary;
}
