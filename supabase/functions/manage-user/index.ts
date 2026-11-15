// Developer-only account management: set a user's password to one the developer chooses
// ("setPassword"), reset a user's password (generates a fresh one and
// reveals it once -- Supabase Auth stores only a bcrypt hash, so an existing password that's
// already been changed by its owner can never actually be "seen" again, only replaced) and
// change a user's username (which also has to repoint their synthetic login email, hence the
// admin API + service-role client rather than a plain table update). Both need the
// service-role key, which must never reach the browser, so both run here as an Edge Function.
// The caller's own JWT is verified against `profiles` (role = developer, active) before any
// privileged action runs -- same shape as create-user's own caller check.
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function randomPassword(length = 12) {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%";
  const bytes = new Uint8Array(length);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => chars[b % chars.length]).join("");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: "Not signed in" }), { status: 401, headers: corsHeaders });
    }
    const { data: callerProfile, error: profErr } = await callerClient
      .from("profiles").select("role,active").eq("id", userData.user.id).single();
    if (profErr || !callerProfile || callerProfile.role !== "developer" || callerProfile.active !== true) {
      return new Response(JSON.stringify({ error: "Developer access required" }), { status: 403, headers: corsHeaders });
    }

    const body = await req.json();
    const action = String(body.action || "");
    const targetUsername = String(body.username || "").trim().toLowerCase();
    if (!targetUsername) return new Response(JSON.stringify({ error: "Username is required" }), { status: 400, headers: corsHeaders });

    const adminClient = createClient(supabaseUrl, serviceKey);
    const { data: target, error: targetErr } = await adminClient
      .from("profiles").select("id,username").eq("username", targetUsername).single();
    if (targetErr || !target) {
      return new Response(JSON.stringify({ error: "User not found" }), { status: 404, headers: corsHeaders });
    }

    if (action === "resetPassword") {
      const newPassword = randomPassword();
      const { error } = await adminClient.auth.admin.updateUserById(target.id, { password: newPassword });
      if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: corsHeaders });
      return new Response(JSON.stringify({ ok: true, username: targetUsername, password: newPassword }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // A password chosen by the developer (as well as "resetPassword", which makes a random one).
    // Supabase stores only its hash. The database drops the person's sign-in PINs when a
    // password changes (trigger pins_drop_on_password_change).
    if (action === "setPassword") {
      const chosen = typeof body.password === "string" ? body.password : "";
      if (chosen.length < 6) return new Response(JSON.stringify({ error: "The password must be at least 6 characters" }), { status: 400, headers: corsHeaders });
      if (chosen.length > 72) return new Response(JSON.stringify({ error: "The password can be at most 72 characters" }), { status: 400, headers: corsHeaders });
      if (chosen !== chosen.trim()) return new Response(JSON.stringify({ error: "The password cannot start or end with a space" }), { status: 400, headers: corsHeaders });
      const { error } = await adminClient.auth.admin.updateUserById(target.id, { password: chosen });
      if (error) return new Response(JSON.stringify({ error: error.message }), { status: 400, headers: corsHeaders });
      return new Response(JSON.stringify({ ok: true, username: targetUsername }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    if (action === "updateUsername") {
      const newUsername = String(body.newUsername || "").trim().toLowerCase();
      if (!newUsername) return new Response(JSON.stringify({ error: "New username is required" }), { status: 400, headers: corsHeaders });
      if (!/^[a-z0-9._-]+$/.test(newUsername)) {
        return new Response(JSON.stringify({ error: "Username can only contain letters, numbers, dots, hyphens and underscores" }), { status: 400, headers: corsHeaders });
      }
      const newEmail = `${newUsername}@bollin.local`;
      const { error: authErr } = await adminClient.auth.admin.updateUserById(target.id, { email: newEmail, email_confirm: true });
      if (authErr) {
        const msg = /already been registered|already exists/i.test(authErr.message)
          ? `Username "${newUsername}" is already taken` : authErr.message;
        return new Response(JSON.stringify({ error: msg }), { status: 400, headers: corsHeaders });
      }
      const { error: profUpdateErr } = await adminClient.from("profiles").update({ username: newUsername }).eq("id", target.id);
      if (profUpdateErr) return new Response(JSON.stringify({ error: profUpdateErr.message }), { status: 400, headers: corsHeaders });
      return new Response(JSON.stringify({ ok: true, oldUsername: targetUsername, newUsername }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    return new Response(JSON.stringify({ error: "Unknown action" }), { status: 400, headers: corsHeaders });
  } catch (e) {
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : String(e) }), { status: 500, headers: corsHeaders });
  }
});
