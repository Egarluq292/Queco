// Preferencias · función «avisar» (Supabase Edge Function)
// Envía un aviso vacío («Hay novedades») al otro móvil cuando llega un mensaje.
// El aviso no lleva nada del contenido: ni texto, ni nombre.
// Las claves de los avisos (VAPID) se generan solas la primera vez y se guardan
// en la tabla «configuracion», cerrada al público.

import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, authorization, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const respuesta = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

const url = Deno.env.get("SUPABASE_URL")!;
const claveServicio = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(url, claveServicio, { auth: { persistSession: false } });

let claves: { publica: string; privada: string } | null = null;

async function obtenerClaves() {
  if (claves) return claves;
  const { data, error } = await db
    .from("configuracion")
    .select("clave, valor")
    .in("clave", ["vapid_publica", "vapid_privada"]);
  if (error) throw error;
  const m = Object.fromEntries((data ?? []).map((f) => [f.clave, f.valor]));
  if (m.vapid_publica && m.vapid_privada) {
    claves = { publica: m.vapid_publica, privada: m.vapid_privada };
    return claves;
  }
  const nuevas = webpush.generateVAPIDKeys();
  const { error: e2 } = await db.from("configuracion").upsert([
    { clave: "vapid_publica", valor: nuevas.publicKey },
    { clave: "vapid_privada", valor: nuevas.privateKey },
  ], { onConflict: "clave", ignoreDuplicates: true });
  if (e2) throw e2;
  claves = null;
  return await obtenerClaves(); // relee por si otra petición las creó a la vez
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return respuesta({ error: "método no permitido" }, 405);

  try {
    const { accion, sala, disp } = await req.json();
    const k = await obtenerClaves();

    if (accion === "clave") return respuesta({ publica: k.publica });

    if (accion === "avisar" || accion === "probar") {
      if (typeof sala !== "string" || !/^[0-9a-f]{64}$/.test(sala) || typeof disp !== "string") {
        return respuesta({ error: "petición no válida" }, 400);
      }
      // «avisar»: al otro móvil. «probar»: a este mismo móvil, a los 8 segundos (para probar con la pantalla apagada)
      let consulta = db.from("suscripciones").select("endpoint, p256dh, auth").eq("sala", sala);
      consulta = accion === "probar" ? consulta.eq("disp", disp) : consulta.neq("disp", disp);
      const { data: subs, error } = await consulta;
      if (error) throw error;
      if (accion === "probar") await new Promise((r) => setTimeout(r, 8000));

      webpush.setVapidDetails("https://egarluq292.github.io", k.publica, k.privada);
      let enviados = 0;
      await Promise.all((subs ?? []).map(async (s) => {
        try {
          await webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
            JSON.stringify({ t: "novedades" }),
            // «high»: Android lo entrega al momento aunque el móvil esté en reposo; si no, puede retrasarlo mucho
            { TTL: 86400, urgency: "high", topic: "novedades" },
          );
          enviados++;
        } catch (e) {
          const codigo = (e as { statusCode?: number }).statusCode;
          if (codigo === 404 || codigo === 410) {
            await db.from("suscripciones").delete().eq("endpoint", s.endpoint);
          }
        }
      }));
      return respuesta({ ok: true, enviados, suscritos: (subs ?? []).length, version: 2 });
    }

    return respuesta({ error: "acción desconocida" }, 400);
  } catch (e) {
    return respuesta({ error: String((e as Error).message ?? e) }, 500);
  }
});
