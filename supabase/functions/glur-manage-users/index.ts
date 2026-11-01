import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://demo78910.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!url || !serviceKey || !anonKey) return json({ error: "Server not configured" }, 503);

    const bearer = req.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
    if (!bearer) return json({ error: "Not authenticated" }, 401);

    const admin = createClient(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: authData, error: authError } = await admin.auth.getUser(bearer);
    if (authError || !authData.user) return json({ error: "Invalid session" }, 401);

    const body = await req.json();
    const { action, shop_id } = body ?? {};
    if (typeof shop_id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(shop_id)) {
      return json({ error: "Invalid shop" }, 400);
    }

    const { data: actor, error: ownerError } = await admin.from("glur_members")
      .select("role").eq("shop_id", shop_id).eq("user_id", authData.user.id).maybeSingle();
    if (ownerError) return json({ error: "Membership check failed" }, 503);
    if (!actor || actor.role !== "owner") return json({ error: "Owner only" }, 403);
    const isOwner = actor.role === "owner";
    const { data: developers, error: developerError } = await admin.from("glur_system_developers").select("user_id");
    if (developerError) return json({ error: "Developer check failed" }, 503);
    const developerIds = new Set((developers ?? []).map((d) => d.user_id));
    const isDeveloper = developerIds.has(authData.user.id);

    if (action === "list") {
      const { data: members, error } = await admin.from("glur_members")
        .select("user_id,role,created_at").eq("shop_id", shop_id).order("created_at");
      if (error) return json({ error: "Unable to list members" }, 500);
      const ids = (members ?? []).map((m) => m.user_id);
      const { data: usernames, error: namesError } = await admin.from("glur_usernames")
        .select("user_id,username").in("user_id", ids.length ? ids : ["00000000-0000-0000-0000-000000000000"]);
      if (namesError) return json({ error: "Unable to list usernames" }, 500);
      const names = new Map((usernames ?? []).map((u) => [u.user_id, u.username]));
      return json({ members: (members ?? []).map((m) => ({ ...m, username: names.get(m.user_id) ?? null, is_developer: developerIds.has(m.user_id), display_role: developerIds.has(m.user_id) ? "developer" : m.role })) });
    }

    if (action === "create") {
      if (body.role === "owner" && !isDeveloper) return json({ error: "Developer only: create Owner" }, 403);
      const { username, password, role } = body;
      if (typeof username !== "string" || !/^[a-z0-9_]{3,30}$/.test(username) ||
          typeof password !== "string" || password.length < 8 || password.length > 128 ||
          !["staff", "manager", "supervisor", ...(isDeveloper ? ["owner"] : [])].includes(role)) {
        return json({ error: "Username must be 3–30 lowercase letters, numbers or underscores; password 8–128 characters; role staff, manager, supervisor or developer-assigned owner" }, 400);
      }
      const { data: existing, error: lookupError } = await admin.from("glur_usernames")
        .select("user_id").eq("username", username).maybeSingle();
      if (lookupError) return json({ error: "Username lookup failed" }, 503);
      if (existing) return json({ error: "Username already in use" }, 409);

      const email = `glur-${crypto.randomUUID()}@example.com`;
      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
      });
      if (createError || !created.user) return json({ error: "Unable to create account" }, 400);
      const newId = created.user.id;
      const { error: nameError } = await admin.from("glur_usernames")
        .insert({ user_id: newId, username });
      if (nameError) {
        await admin.auth.admin.deleteUser(newId);
        return json({ error: "Username unavailable or could not be saved" }, 409);
      }
      const { error: memberError } = await admin.from("glur_members")
        .insert({ shop_id, user_id: newId, role });
      if (memberError) {
        await admin.from("glur_usernames").delete().eq("user_id", newId);
        await admin.auth.admin.deleteUser(newId);
        return json({ error: "Unable to assign shop role" }, 500);
      }
      return json({ ok: true, user_id: newId, username, role }, 201);
    }

    if (action === "set_role") {
      if (body.role === "owner" && !isDeveloper) return json({ error: "Developer only: assign Owner" }, 403);
      const { user_id, role } = body;
      if (typeof user_id !== "string" || !["staff", "manager", "supervisor", ...(isDeveloper ? ["owner"] : [])].includes(role) || user_id === authData.user.id) {
        return json({ error: "Invalid role change" }, 400);
      }
      const { data: target, error: targetError } = await admin.from("glur_members")
        .select("role").eq("shop_id", shop_id).eq("user_id", user_id).maybeSingle();
      if (targetError) return json({ error: "Unable to load member" }, 503);
      if (!target || developerIds.has(user_id) || (target.role === "owner" && !isDeveloper) || (!isOwner && target.role === "manager")) return json({ error: "Insufficient permission for this account" }, 403);
      const { data: updated, error } = await admin.from("glur_members").update({ role })
        .eq("shop_id", shop_id).eq("user_id", user_id).in("role", ["staff", "manager", "supervisor", ...(isDeveloper ? ["owner"] : [])])
        .select("user_id").maybeSingle();
      if (error || !updated) return json({ error: "Unable to update role" }, 500);
      return json({ ok: true });
    }

    if (action === "remove") {
      const { user_id } = body;
      if (typeof user_id !== "string" || user_id === authData.user.id) return json({ error: "Invalid member" }, 400);
      const { data: target, error: targetError } = await admin.from("glur_members")
        .select("role").eq("shop_id", shop_id).eq("user_id", user_id).maybeSingle();
      if (targetError) return json({ error: "Unable to load member" }, 503);
      if (!target || developerIds.has(user_id) || (target.role === "owner" && !isDeveloper) || (!isOwner && target.role === "manager")) return json({ error: "Insufficient permission for this account" }, 403);
      const { data: removed, error } = await admin.from("glur_members").delete()
        .eq("shop_id", shop_id).eq("user_id", user_id).in("role", ["staff", "manager", "supervisor", ...(isDeveloper ? ["owner"] : [])])
        .select("user_id").maybeSingle();
      if (error || !removed) return json({ error: "Unable to remove shop access" }, 500);
      return json({ ok: true });
    }
    return json({ error: "Unknown action" }, 400);
  } catch (err) {
    console.error("glur-manage-users error", err instanceof Error ? err.message : "unknown");
    return json({ error: "Invalid request" }, 400);
  }
});
