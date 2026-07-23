// Edge Function: lectura en vivo de reservas reales desde la API oficial
// "Third Party API" de Playtomic para clubs (client_id/secret). Sirve para
// pintar en la Parrilla las clases que existen de verdad en Playtomic sin
// guardar copia aquí: si se cancela allí, desaparece de aquí automáticamente
// en la siguiente carga. Nunca escribe nada en Playtomic.
//
// Referencia pública: https://third-party.playtomic.io/ (Playtomic Third
// Party API). Las credenciales se generan en Playtomic Manager > Settings >
// Developer tools.
//
// Secrets necesarios (Supabase dashboard > Edge Functions > Secrets):
//   PLAYTOMIC_CLIENT_ID, PLAYTOMIC_CLIENT_SECRET, PLAYTOMIC_TENANT_ID
//
// Requiere sesión de Supabase (solo la llama la web ya logueada).
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Host real de la API (distinto del sitio de documentación, que lleva guion:
// third-party.playtomic.io).
const PLAYTOMIC_AUTH_URL = "https://thirdparty.playtomic.io/api/v1/oauth/token";
const PLAYTOMIC_BOOKINGS_URL = "https://thirdparty.playtomic.io/api/v1/bookings";

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getPlaytomicToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now()) {
    return cachedToken.token;
  }

  const res = await fetch(PLAYTOMIC_AUTH_URL, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    // El campo se llama "secret", no "client_secret" (confirmado en la doc
    // pública de la Third Party API de Playtomic).
    body: JSON.stringify({
      client_id: Deno.env.get("PLAYTOMIC_CLIENT_ID"),
      secret: Deno.env.get("PLAYTOMIC_CLIENT_SECRET"),
    }),
  });

  if (!res.ok) {
    throw new Error(`No se pudo autenticar contra Playtomic: ${res.status} ${await res.text()}`);
  }

  const json = await res.json();
  const accessToken = json.access_token ?? json.accessToken ?? json.token;
  if (!accessToken) {
    throw new Error(`Login OK pero no se encontró el token en la respuesta: ${JSON.stringify(json)}`);
  }
  // Cacheamos el token en memoria del proceso (con margen) para no pedir uno
  // nuevo en cada carga de la Parrilla; se renueva solo cuando caduca.
  cachedToken = {
    token: accessToken,
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

    // La API solo conserva reservas de los últimos ~3 meses y espera fecha+
    // hora ISO en start_booking_date/end_booking_date, no solo la fecha.
    // Un club con muchas pistas puede tener muchas más de 100 reservas en un
    // solo día (partidos + clases), así que hay que paginar: si no, se
    // pierden en silencio las reservas que caen en la página 2 en adelante
    // (la API las ordena de más reciente a más antigua, así que lo que se
    // pierde suele ser precisamente lo más temprano del día).
    const PAGE_SIZE = 100;
    const MAX_PAGES = 20; // margen de seguridad para no encadenar páginas sin fin
    let bookings: any[] = [];
    for (let page = 0; page < MAX_PAGES; page++) {
      const params = new URLSearchParams({
        tenant_id: tenantId ?? "",
        start_booking_date: `${dateFrom}T00:00:00`,
        end_booking_date: `${dateTo}T23:59:59`,
        size: String(PAGE_SIZE),
        page: String(page),
      });

      const bookingsRes = await fetch(`${PLAYTOMIC_BOOKINGS_URL}?${params}`, {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!bookingsRes.ok) {
        const detail = await bookingsRes.text();
        return new Response(JSON.stringify({ error: "Fallo al leer reservas de Playtomic", detail }), {
          status: 502,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      const json = await bookingsRes.json();
      const pageItems: any[] = Array.isArray(json) ? json : json.data ?? [];
      bookings = bookings.concat(pageItems);
      if (pageItems.length < PAGE_SIZE) break; // última página
    }

    // Playtomic devuelve en el mismo endpoint partidos entre socios, clases
    // de academia, clases particulares y torneos, distinguidos por
    // `booking_type`. El filtrado de qué tipos interesan (clases vs.
    // partidos) se hace en el frontend, no aquí, para poder ajustarlo sin
    // tener que redesplegar esta función cada vez.
    //
    // Normalizamos al formato mínimo que consume la Parrilla/KPIs. Ojo:
    // `coach_ids` son IDs de Playtomic, no nombres — si tu cuenta no expone
    // el nombre del profesor en este mismo payload, el casado por nombre en
    // KPIs/Playtomic Manager (trainers.external_system_name) no funcionará
    // hasta resolver esos IDs contra el endpoint de profesores/empleados de
    // Playtomic (no cubierto aquí; revisar la respuesta real una vez
    // conectado para confirmar si añade el nombre en algún otro campo).
    const normalized = bookings.map((b: any) => ({
      id: b.booking_id ?? b.id,
      court: b.resource_name ?? b.resource_id,
      date: (b.booking_start_date ?? "").slice(0, 10),
      start: (b.booking_start_date ?? "").slice(11, 16),
      end: (b.booking_end_date ?? "").slice(11, 16),
      booking_type: b.booking_type ?? null,
      is_canceled: b.is_canceled ?? (b.status === "CANCELED"),
      trainer_name: b.instructor_name ?? b.coach_name ?? null,
      coach_ids: b.coach_ids ?? [],
      payment_status: b.payment_status ?? null,
      participants: b.participant_info?.participants?.length ?? null,
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
