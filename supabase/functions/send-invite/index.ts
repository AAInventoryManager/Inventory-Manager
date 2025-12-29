// Supabase Edge Function: send-invite
// Sends invitation emails via Mailtrap using the company_invites lifecycle RPCs.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type AuthResult =
  | { ok: true; supabase: SupabaseClient; companyId: string | null; userEmail: string }
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

async function authorizeRequest(
  req: Request,
  body: Record<string, unknown>,
  requireCompanyId: boolean
): Promise<AuthResult> {
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

  let companyId: string | null = String(body?.company_id || body?.companyId || "").trim() || null;
  if (!companyId && requireCompanyId) {
    const { data, error } = await supabase.rpc("get_user_company_id");
    if (error) {
      return { ok: false, status: 400, error: "Missing company_id" };
    }
    companyId = String(data || "").trim() || null;
  }
  if (requireCompanyId && !companyId) {
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

function resolveInviteAppUrl(req: Request, body: Record<string, unknown>): string {
  const explicit = String(body?.app_url || body?.appUrl || "").trim();
  if (explicit) return explicit;
  const origin = req.headers.get("origin");
  if (origin) return origin;
  const envUrl =
    Deno.env.get("INVITE_APP_URL") ||
    Deno.env.get("APP_URL") ||
    Deno.env.get("SITE_URL") ||
    "";
  return String(envUrl || "").trim();
}

function buildInviteUrl(appUrl: string, inviteId: string): string {
  if (!appUrl) return "";
  try {
    const url = new URL(appUrl);
    url.searchParams.set("invite", inviteId);
    return url.toString();
  } catch {
    const clean = appUrl.replace(/\?.*$/, "").replace(/\/+$/, "");
    return clean ? `${clean}?invite=${inviteId}` : "";
  }
}

async function ensureInviteTierAccess(supabase: SupabaseClient, companyId: string) {
  const { data: tierAllowed, error: tierError } = await supabase.rpc("has_tier_access", {
    p_company_id: companyId,
    p_required_tier: "business",
  });
  if (tierError) {
    return { ok: false, status: 500, error: "Failed to check tier" };
  }
  if (!tierAllowed) {
    return { ok: false, status: 403, error: "Feature not available for current plan" };
  }
  return { ok: true };
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
    const inviteIdInput = String(body?.invite_id || body?.inviteId || "").trim();
    const requireCompanyId = !inviteIdInput;
    const auth = await authorizeRequest(req, body, requireCompanyId);
    if (!auth.ok) {
      return new Response(
        JSON.stringify({ ok: false, error: auth.error }),
        { status: auth.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const replyTo = auth.userEmail;
    if (!looksLikeEmail(replyTo)) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid reply-to email" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    let inviteId = inviteIdInput;
    let email = "";
    let role = "";
    let expiresAt = "";
    let companyId = auth.companyId ? String(auth.companyId).trim() : "";
    let resendCount: number | null = null;
    let lastSentAt: string | null = null;

    if (inviteId) {
      const { data: inviteRow, error: inviteError } = await auth.supabase
        .from("company_invites")
        .select("id,email,role,company_id,expires_at,status")
        .eq("id", inviteId)
        .maybeSingle();

      if (inviteError) {
        return new Response(
          JSON.stringify({ ok: false, error: "Failed to load invite" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      if (!inviteRow) {
        return new Response(
          JSON.stringify({ ok: false, error: "Invite not found" }),
          { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      if (inviteRow.status !== "pending") {
        return new Response(
          JSON.stringify({ ok: false, error: "Invite is not pending" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const expiresAtValue = inviteRow.expires_at ? new Date(inviteRow.expires_at) : null;
      if (expiresAtValue && expiresAtValue <= new Date()) {
        return new Response(
          JSON.stringify({ ok: false, error: "Invite has expired" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      companyId = String(inviteRow.company_id || "").trim();
      if (!companyId) {
        return new Response(
          JSON.stringify({ ok: false, error: "Invite company missing" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const tierCheck = await ensureInviteTierAccess(auth.supabase, companyId);
      if (!tierCheck.ok) {
        return new Response(
          JSON.stringify({ ok: false, error: tierCheck.error }),
          { status: tierCheck.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const { data: resendData, error: resendError } = await auth.supabase.rpc("resend_company_invite", {
        p_invite_id: inviteId,
      });
      if (resendError) {
        return new Response(
          JSON.stringify({ ok: false, error: resendError.message || "Resend failed" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      if (resendData && resendData.success === false) {
        const msg = resendData.error || "Resend failed";
        const status = isPermissionError(msg) ? 403 : 400;
        return new Response(
          JSON.stringify({ ok: false, error: msg }),
          { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
      resendCount = typeof resendData?.resend_count === "number" ? resendData.resend_count : null;
      lastSentAt = resendData?.last_sent_at ? String(resendData.last_sent_at) : null;
      email = String(inviteRow.email || "").trim();
      role = String(inviteRow.role || "member").trim() || "member";
      expiresAt = inviteRow.expires_at ? String(inviteRow.expires_at) : "";
    } else {
      email = String(body?.email || body?.to || body?.toEmail || "").trim();
      role = String(body?.role || "member").trim() || "member";
      if (!companyId) {
        return new Response(
          JSON.stringify({ ok: false, error: "Missing company_id" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      if (!looksLikeEmail(email)) {
        return new Response(
          JSON.stringify({ ok: false, error: "Invalid recipient email" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      if (!["admin", "member", "viewer"].includes(role)) {
        return new Response(
          JSON.stringify({ ok: false, error: "Invalid role" }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const tierCheck = await ensureInviteTierAccess(auth.supabase, companyId);
      if (!tierCheck.ok) {
        return new Response(
          JSON.stringify({ ok: false, error: tierCheck.error }),
          { status: tierCheck.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      const expiresAtValue = String(body?.expires_at || "").trim();
      const expiresAtDate = expiresAtValue ? new Date(expiresAtValue) : new Date(Date.now() + 7 * 24 * 60 * 60 * 1000);
      const { data: inviteData, error: inviteError } = await auth.supabase.rpc("send_company_invite", {
        p_company_id: companyId,
        p_email: email,
        p_role: role,
        p_expires_at: expiresAtDate.toISOString(),
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
          JSON.stringify({ ok: false, error: msg }),
          { status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      inviteId = inviteData?.invite_id ? String(inviteData.invite_id).trim() : "";
      expiresAt = inviteData?.expires_at ? String(inviteData.expires_at) : expiresAtDate.toISOString();
    }

    if (!inviteId) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invite id missing" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!email || !looksLikeEmail(email)) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid recipient email" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: company, error: companyError } = await auth.supabase
      .from("companies")
      .select("name")
      .eq("id", companyId)
      .maybeSingle();
    if (companyError) {
      return new Response(
        JSON.stringify({ ok: false, error: "Failed to load company" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const companyName = String(company?.name || "").trim();
    const appUrl = resolveInviteAppUrl(req, body);
    const inviteUrl = buildInviteUrl(appUrl, inviteId);
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
      await sendViaMailtrap({ to: email, subject, text, html, replyTo });
    } catch (e) {
      const message = e instanceof Error ? e.message : "Email send failed";
      return new Response(
        JSON.stringify({
          ok: false,
          error: message,
          invite_url: inviteUrl,
          invite_id: inviteId,
          expires_at: expiresAt || null,
          resend_count: resendCount,
          last_sent_at: lastSentAt,
        }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({
        ok: true,
        sent: true,
        invite_url: inviteUrl,
        invite_id: inviteId,
        expires_at: expiresAt || null,
        resend_count: resendCount,
        last_sent_at: lastSentAt,
      }),
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
