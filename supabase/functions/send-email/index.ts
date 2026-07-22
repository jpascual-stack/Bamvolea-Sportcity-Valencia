// Edge Function: envío real de email vía Resend.
// Requiere sesión de Supabase (la llama solo la web ya logueada).
// Secrets necesarios (Supabase dashboard > Edge Functions > send-email):
//   RESEND_API_KEY, RESEND_FROM (ej: "Bamvolea Sportcity Valencia <no-reply@tudominio.com>")
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "No autorizado" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Verificamos que la llamada viene de un usuario logueado real,
    // no aceptamos envíos anónimos (evita que cualquiera use la función
    // como relay de spam).
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: userData, error: userError } = await supabase.auth.getUser();
    if (userError || !userData?.user) {
      return new Response(JSON.stringify({ error: "Sesión no válida" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { to, subject, html, attachmentUrl, attachmentName } = await req.json();

    if (!to || !subject || !html) {
      return new Response(JSON.stringify({ error: "Faltan campos: to, subject, html" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const recipients = Array.isArray(to) ? to : [to];

    // Cada destinatario recibe su propio email individual (no una única
    // copia oculta a todos), tal como pide el modelo de negocio.
    const results = [];
    for (const recipient of recipients) {
      const payload: Record<string, unknown> = {
        from: Deno.env.get("RESEND_FROM"),
        to: [recipient],
        subject,
        html,
      };

      if (attachmentUrl) {
        const fileRes = await fetch(attachmentUrl);
        if (fileRes.ok) {
          const buf = new Uint8Array(await fileRes.arrayBuffer());
          payload.attachments = [{
            filename: attachmentName || "adjunto",
            content: btoa(String.fromCharCode(...buf)),
          }];
        }
      }

      const resendRes = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
          Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(payload),
      });

      const resendJson = await resendRes.json();
      results.push({ to: recipient, ok: resendRes.ok, response: resendJson });
    }

    const anyFailed = results.some((r) => !r.ok);
    return new Response(JSON.stringify({ results }), {
      status: anyFailed ? 207 : 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
