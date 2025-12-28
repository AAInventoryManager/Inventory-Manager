// Supabase Edge Function: send-invite
// Sends invitation emails via Mailtrap using invite_user RPC

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type AuthResult =
  | { ok: true; supabase: SupabaseClient; companyId: string; userEmail: string }
  | { ok: false; status: number; error: string };

function getSupabaseClient(token: string) {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") || "";
  if (!supabaseUrl || !supabaseAnonKey) {
    throw new Error("Missing Supabase configuration");
  }

  return createClient(supabaseUrl, supabaseAnonKey, {
    global: {
      headers: { Authorization: `Bearer ${token}` },
    },
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });
}

async function authorizeRequest(req: Request, body: Record<string, unknown>): Promise<AuthResult> {
  const authHeader = req.headers.get("Authorization") || "";
  if (!authHeader) {
    return { ok: false, status: 401, error: "Missing Authorization header" };
  }
  if (!authHeader.startsWith("Bearer ")) {
    return { ok: false, status: 401, error: "Authorization header must use Bearer scheme" };
  }
  const token = authHeader.slice(7).trim();
  if (!token) {
    return { ok: false, status: 401, error: "Missing JWT token" };
  }

  const supabase = getSupabaseClient(token);
  const { data: userData, error: userError } = await supabase.auth.getUser(token);
  if (userError || !userData?.user) {
    return { ok: false, status: 401, error: "Invalid or expired JWT token" };
  }
  const userEmail = String(userData.user.email || "").trim();

  let companyId = String(body?.company_id || body?.companyId || "").trim();
  if (!companyId) {
    const { data, error } = await supabase.rpc("get_user_company_id");
    if (error) {
      return { ok: false, status: 400, error: "Missing company_id" };
    }
    companyId = String(data || "").trim();
  }
  if (!companyId) {
    return { ok: false, status: 400, error: "Missing company_id" };
  }

  return { ok: true, supabase, companyId, userEmail };
}

function looksLikeEmail(email: string): boolean {
  const s = String(email || "").trim();
  if (!s || s.length > 254) return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
}

async function sendViaMailtrap({
  to,
  subject,
  text,
  html,
  replyTo,
}: {
  to: string;
  subject: string;
  text?: string;
  html?: string;
  replyTo?: string;
}) {
  const token = Deno.env.get("MAILTRAP_API_TOKEN") || "";
  const fromEmail = Deno.env.get("MAILTRAP_FROM_EMAIL") || "";
  const fromName = Deno.env.get("MAILTRAP_FROM_NAME") || "Modulus Software, LLC";
  const baseUrl = Deno.env.get("MAILTRAP_API_BASE_URL") || "https://send.api.mailtrap.io/api/send";

  if (!token) throw new Error("MAILTRAP_API_TOKEN is not configured");
  if (!fromEmail) throw new Error("MAILTRAP_FROM_EMAIL is not configured");

  const payload: Record<string, unknown> = {
    from: { email: fromEmail, name: fromName },
    to: [{ email: to }],
    subject,
  };

  if (html) {
    payload.html = html;
  } else if (text) {
    payload.text = text;
  }

  if (replyTo) {
    payload.headers = { "Reply-To": replyTo };
  }

  const resp = await fetch(baseUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  const raw = await resp.text();
  let parsed = null;
  try {
    parsed = raw ? JSON.parse(raw) : null;
  } catch {
    parsed = null;
  }

  if (!resp.ok) {
    const msg = parsed?.message || parsed?.error || `Mailtrap error (${resp.status})`;
    throw new Error(msg);
  }

  return parsed || { ok: true };
}

function isPermissionError(message: string): boolean {
  const msg = String(message || "").toLowerCase();
  return msg.includes("permission") || msg.includes("feature not available") || msg.includes("plan");
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

    const auth = await authorizeRequest(req, body);
    if (!auth.ok) {
      return new Response(
        JSON.stringify({ ok: false, error: auth.error }),
        { status: auth.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const email = String(body?.email || body?.to || body?.toEmail || "").trim();
    const role = String(body?.role || "member").trim() || "member";

    if (!looksLikeEmail(email)) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid recipient email" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!looksLikeEmail(auth.userEmail)) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid reply-to email" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!['admin', 'member', 'viewer'].includes(role)) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid role" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: inviteData, error: inviteError } = await auth.supabase.rpc("invite_user", {
      p_company_id: auth.companyId,
      p_email: email,
      p_role: role,
    });

    if (inviteError) {
      return new Response(
        JSON.stringify({ ok: false, error: inviteError.message || "Invite failed" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (inviteData && inviteData.success === false) {
      const msg = inviteData.error || "Invite failed";
      const status = isPermissionError(msg) ? 403 : 400;
      return new Response(
        JSON.stringify({ ok: false, error: msg, invite_url: inviteData.invite_url || "" }),
        { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const inviteUrl = inviteData?.invite_url ? String(inviteData.invite_url).trim() : "";
    const companyName = inviteData?.company_name ? String(inviteData.company_name).trim() : "";

    if (!inviteUrl) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invite URL missing" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const displayCompany = companyName || "your company";
    const subject = `You're invited to ${displayCompany} on Inventory Manager`;
    const text =
      `You've been invited to join ${displayCompany} as ${role}.\n` +
      `Accept the invitation: ${inviteUrl}\n` +
      `This link expires in 7 days.`;
    const html =
      `<div style="font-family:Arial,sans-serif;line-height:1.5;color:#111">` +
        `<h2 style="margin:0 0 12px 0;">You're invited to ${displayCompany}</h2>` +
        `<p style="margin:0 0 12px 0;">You have been invited to join ${displayCompany} as <strong>${role}</strong>.</p>` +
        `<p style="margin:0 0 16px 0;">` +
          `<a href="${inviteUrl}" style="display:inline-block;padding:10px 16px;background:#1f2937;color:#fff;text-decoration:none;border-radius:6px;">Accept Invitation</a>` +
        `</p>` +
        `<p style="margin:0;color:#555;">This link expires in 7 days.</p>` +
      `</div>`;

    const allowedDomainsRaw = Deno.env.get("ALLOWED_RECIPIENT_DOMAINS") || "";
    if (allowedDomainsRaw) {
      const allowedDomains = new Set(
        allowedDomainsRaw.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean)
      );
      const domain = email.split("@").pop()?.toLowerCase() || "";
      if (!allowedDomains.has(domain)) {
        return new Response(
          JSON.stringify({ ok: false, error: "Recipient domain not allowed", invite_url: inviteUrl }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    try {
      await sendViaMailtrap({ to: email, subject, text, html, replyTo: auth.userEmail });
    } catch (e) {
      const message = e instanceof Error ? e.message : "Email send failed";
      return new Response(
        JSON.stringify({ ok: false, error: message, invite_url: inviteUrl }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ ok: true, sent: true, invite_url: inviteUrl }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (e) {
    const message = e instanceof Error ? e.message : "Send failed";
    return new Response(
      JSON.stringify({ ok: false, error: message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
