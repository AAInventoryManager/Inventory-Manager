// Supabase Edge Function: send-order
// Sends order emails via Mailtrap API

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

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

  // Send HTML only for proper rendering
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

serve(async (req) => {
  // Handle CORS preflight
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
    const body = await req.json();

    const to = String(body?.to || body?.toEmail || body?.email || "").trim();
    const subject = String(body?.subject || "Material Order").trim();
    const text = String(body?.text || body?.body || "").trim();
    const html = String(body?.html || "").trim();
    const replyTo = String(body?.replyTo || body?.reply_to || "").trim();

    // Validation
    if (!looksLikeEmail(to)) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid recipient email" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (replyTo && !looksLikeEmail(replyTo)) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid reply-to email" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!subject || subject.length > 200) {
      return new Response(
        JSON.stringify({ ok: false, error: "Invalid subject" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!text && !html) {
      return new Response(
        JSON.stringify({ ok: false, error: "Missing body" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Optional: Check allowed domains
    const allowedDomainsRaw = Deno.env.get("ALLOWED_RECIPIENT_DOMAINS") || "";
    if (allowedDomainsRaw) {
      const allowedDomains = new Set(
        allowedDomainsRaw.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean)
      );
      const domain = to.split("@").pop()?.toLowerCase() || "";
      if (!allowedDomains.has(domain)) {
        return new Response(
          JSON.stringify({ ok: false, error: "Recipient domain not allowed" }),
          { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    const result = await sendViaMailtrap({ to, subject, text, html, replyTo });

    return new Response(
      JSON.stringify({ ok: true, result }),
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
