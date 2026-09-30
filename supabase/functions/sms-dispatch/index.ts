// sms-dispatch: called once a minute by pg_cron (via pg_net) with the x-dispatch-secret header.
// Hands due rota texts to the clinic phone's SMS gateway and records what happened. It never
// creates texts -- see core.ts. Deployed with verify_jwt = false (config.toml): the caller is
// the database's cron job, authenticated by DISPATCH_SECRET instead of a user login.
//
// Secrets (supabase secrets set --project-ref <ref> ...), never in the repo:
//   DISPATCH_SECRET      shared with the cron job
//   SMS_MODE             'live' to really send; anything else (default) is a dry run
//   SMS_ALLOWLIST        staging: comma-separated mobiles that may really be texted
//   SMS_GATEWAY_USER / SMS_GATEWAY_PASS   from the SMS Gateway app (cloud server)
//   SMS_TTL_SECONDS      optional, default 12 hours
import { createClient } from "npm:@supabase/supabase-js@2";
import { readConfig, runDispatch, secretsMatch } from "./core.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  if (!secretsMatch(req.headers.get("x-dispatch-secret") || "", Deno.env.get("DISPATCH_SECRET") || "")) {
    return new Response("Unauthorized", { status: 401 });
  }
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  try {
    const summary = await runDispatch(
      async (fn, args) => {
        const { data, error } = await sb.rpc(fn, args);
        return { data, error: error ? { message: error.message } : null };
      },
      (url, init) => fetch(url, init),
      readConfig((k) => Deno.env.get(k)),
    );
    return new Response(JSON.stringify(summary), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    console.error("sms-dispatch failed:", e);
    return new Response(JSON.stringify({ error: String((e as Error)?.message || e) }), {
      status: 500, headers: { "Content-Type": "application/json" },
    });
  }
});
