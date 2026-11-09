// Sign in with a 4-digit PIN on a computer where the person set one up.
//
// The page sends {username, device, pin}. `device` is the long random key that computer's
// browser was given when the PIN was set. The database function pin_check (service role only)
// checks the three together, counts wrong tries and deletes the PIN after five. Only when it
// says yes does this function ask Supabase Auth for a one-time sign-in token for that person
// (no email is sent) and hand it back; the page exchanges it for a normal session.
//
// Not called by a signed-in user, so verify_jwt is off in config.toml. What protects it is the
// device key + PIN + the five-try limit, all checked in the database.
// Always answers 200 with {ok:false, reason} for a refusal, so the page can read the reason.
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: corsHeaders });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ ok: false, reason: "bad_request" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const username = String(body.username || "").trim().toLowerCase();
    const device = String(body.device || "");
    const pin = String(body.pin || "");
    if (!username || username.length > 80 || device.length < 32 || device.length > 200 || !/^\d{4}$/.test(pin)) {
      return reply({ ok: false, reason: "no_pin" });
    }

    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: chk, error: chkErr } = await admin.rpc("pin_check", {
      p_username: username, p_device: device, p_pin: pin,
    });
    if (chkErr) return reply({ ok: false, reason: "error" });
    if (!chk || chk.ok !== true) {
      return reply({ ok: false, reason: String((chk && chk.reason) || "no_pin"), left: chk && chk.left });
    }

    const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
      type: "magiclink", email: String(chk.email),
    });
    const tokenHash = link && link.properties && link.properties.hashed_token;
    if (linkErr || !tokenHash) return reply({ ok: false, reason: "error" });
    return reply({ ok: true, token_hash: tokenHash });
  } catch (_e) {
    return reply({ ok: false, reason: "error" });
  }
});
