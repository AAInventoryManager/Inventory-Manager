// Supabase Edge Function: accept-invite
// Creates an auth user for a valid invitation and returns the email for sign-in.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function getServiceClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (!supabaseUrl || !serviceKey) {
    throw new Error("Missing Supabase configuration");
  }

  return createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

function looksLikeEmail(email: string): boolean {
  const s = String(email || "").trim();
  if (!s || s.length > 254) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ ok: false, error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  try {
    const body = (await req.json()) as Record<string, unknown>;
    const token = String(body?.token || "").trim();
    const password = String(body?.password || "");

    if (!token) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invite token is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!password || password.length < 8) {
      return new Response(
        JSON.stringify({ ok: false, error: "Password must be at least 8 characters" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabase = getServiceClient();

    const { data: invite, error: inviteError } = await supabase
      .from("invitations")
      .select("id,email,company_id,role,expires_at,accepted_at")
      .eq("token", token)
      .maybeSingle();

    if (inviteError) {
      return new Response(
        JSON.stringify({ ok: false, error: "Failed to load invitation" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!invite || !invite.email) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid or expired invitation" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (invite.accepted_at) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invitation already accepted" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (invite.expires_at && new Date(invite.expires_at) <= new Date()) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invitation has expired" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const email = String(invite.email || "").trim();
    if (!looksLikeEmail(email)) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid invitation email" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { error: createError } = await supabase.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });

    if (createError) {
      const msg = createError.message || "Failed to create account";
      if (msg.toLowerCase().includes("already")) {
        return new Response(
          JSON.stringify({
            ok: false,
            code: "ExistingUser",
            error: "Account already exists. Please sign in.",
            email,
          }),
          { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      return new Response(
        JSON.stringify({ ok: false, error: msg, email }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ ok: true, email }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : "Invite setup failed";
    return new Response(
      JSON.stringify({ ok: false, error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
