import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://aymanagag.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed." }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return jsonResponse({ error: "You must be signed in as an administrator." }, 401);
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !anonKey || !serviceRoleKey) {
      console.error("Required Supabase Edge Function environment variables are missing.");
      return jsonResponse({ error: "Invitation service is not configured. Please contact the system administrator." }, 500);
    }

    const token = authorization.slice("Bearer ".length);
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: userData, error: userError } = await callerClient.auth.getUser(token);
    if (userError || !userData.user) {
      return jsonResponse({ error: "Your session is invalid or has expired. Please sign in again." }, 401);
    }

    const { data: callerProfile, error: profileError } = await callerClient
      .from("profiles")
      .select("role")
      .eq("id", userData.user.id)
      .maybeSingle();

    if (profileError || callerProfile?.role !== "admin") {
      return jsonResponse({ error: "Only an administrator can invite assistants." }, 403);
    }

    let payload: { email?: unknown; full_name?: unknown };
    try {
      payload = await req.json();
    } catch {
      return jsonResponse({ error: "Please provide a valid invitation request." }, 400);
    }

    const email = typeof payload.email === "string" ? payload.email.trim().toLowerCase() : "";
    const fullName = typeof payload.full_name === "string" ? payload.full_name.trim() : "";

    if (!email || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return jsonResponse({ error: "Please enter a valid email address." }, 400);
    }
    if (!fullName || fullName.length > 120) {
      return jsonResponse({ error: "Please enter a name (maximum 120 characters)." }, 400);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: inviteData, error: inviteError } = await adminClient.auth.admin.inviteUserByEmail(
      email,
      {
        data: { full_name: fullName },
        redirectTo: "https://aymanagag.github.io/robotic-assist-test/",
      },
    );

    if (inviteError) {
      console.error("Assistant invitation failed:", inviteError.message);
      const message = /already|registered|exists/i.test(inviteError.message)
        ? "This email address is already registered. Ask an administrator to review the existing account."
        : "The invitation could not be sent. Please check the email address and try again later.";
      return jsonResponse({ error: message }, 400);
    }

    return jsonResponse({
      success: true,
      message: "Invitation email sent. The new account will have assistant permissions.",
    }, 201);
  } catch (error) {
    console.error("Unexpected invitation service error:", error);
    return jsonResponse({ error: "The invitation could not be completed. Please try again later." }, 500);
  }
});
