// Edge Function: lectura en vivo de reservas reales desde la API oficial
// de Playtomic (client_id/secret). Sirve para pintar en la Parrilla las
// clases que existen de verdad en Playtomic sin guardar copia aquí: si se
// cancela allí, desaparece de aquí automáticamente en la siguiente carga.
// Nunca escribe nada en Playtomic.
//
// Secrets necesarios (Supabase dashboard > Edge Functions > playtomic-proxy):
//   PLAYTOMIC_CLIENT_ID, PLAYTOMIC_CLIENT_SECRET, PLAYTOMIC_TENANT_ID
//
// Requiere sesión de Supabase (solo la llama la web ya logueada).
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const PLAYTOMIC_AUTH_URL = "https://playtomic.io/api/v3/auth/login";
const PLAYTOMIC_BOOKINGS_URL = "https://playtomic.io/api/v1/tenant-bookings";

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getPlaytomicToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now()) {
    return cachedToken.token;
  }

  const res = await fetch(PLAYTOMIC_AUTH_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      client_id: Deno.env.get("PLAYTOMIC_CLIENT_ID"),
      client_secret: Deno.env.get("PLAYTOMIC_CLIENT_SECRET"),
      grant_type: "client_credentials",
    }),
  });

  if (!res.ok) {
    throw new Error(`No se pudo autenticar contra Playtomic: ${res.status} ${await res.text()}`);
  }

  const json = await res.json();
  // Cacheamos el token en memoria del proceso (con margen) para no pedir uno
  // nuevo en cada carga de la Parrilla; se renueva solo cuando caduca.
  cachedToken = {
    token: json.access_token,
    expiresAt: Date.now() + ((json.expires_in ?? 300) - 30) * 1000,
  };
  return cachedToken.token;
}

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

    const url = new URL(req.url);
    const dateFrom = url.searchParams.get("from");
    const dateTo = url.searchParams.get("to");
    if (!dateFrom || !dateTo) {
      return new Response(JSON.stringify({ error: "Parámetros requeridos: from, to (YYYY-MM-DD)" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const token = await getPlaytomicToken();
    const tenantId = Deno.env.get("PLAYTOMIC_TENANT_ID");

    const bookingsRes = await fetch(
      `${PLAYTOMIC_BOOKINGS_URL}?tenant_id=${tenantId}&from=${dateFrom}&to=${dateTo}`,
      { headers: { Authorization: `Bearer ${token}` } },
    );

    if (!bookingsRes.ok) {
      const detail = await bookingsRes.text();
      return new Response(JSON.stringify({ error: "Fallo al leer reservas de Playtomic", detail }), {
        status: 502,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const bookings = await bookingsRes.json();

    // Normalizamos al formato mínimo que consume la Parrilla/KPIs: el resto
    // del payload de Playtomic no nos interesa y así reducimos acoplamiento
    // si cambian campos que no usamos.
    const normalized = (Array.isArray(bookings) ? bookings : bookings.data ?? []).map((b: any) => ({
      id: b.owner_id ?? b.id,
      court: b.resource_id ?? b.court_name,
      date: b.start_date ?? b.date,
      start: b.start_time ?? b.start,
      end: b.end_time ?? b.end,
      trainer_name: b.instructor_name ?? b.owner_name ?? null,
      payment_status: b.payment_status ?? null,
      participants: b.players?.length ?? null,
    }));

    return new Response(JSON.stringify({ bookings: normalized }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
