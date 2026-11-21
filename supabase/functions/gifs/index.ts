// Preferencias · función «gifs» (Supabase Edge Function)
// Intermediario con GIPHY: la app nunca se conecta a GIPHY directamente,
// así GIPHY no ve la IP ni el móvil de quien busca. La clave de GIPHY se guarda
// como secreto de Supabase (GIPHY_API_KEY), nunca en el código de la app.

const CLAVE = Deno.env.get("GIPHY_API_KEY") ?? "";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, authorization, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...CORS, "Content-Type": "application/json" } });

type Imagen = { webp?: string; width?: string; height?: string; url?: string };
type Gif = { id: string; images: Record<string, Imagen> };

// Solo se descargan archivos de los servidores de imágenes de GIPHY
const HOST_GIPHY = /^(media\d*|i)\.giphy\.com$/;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "método no permitido" }, 405);
  if (!CLAVE) return json({ error: "Falta la clave de GIPHY (secreto GIPHY_API_KEY en Supabase)" }, 500);

  try {
    const p = await req.json();

    if (p.accion === "buscar" || p.accion === "tendencias") {
      const qs = new URLSearchParams({
        api_key: CLAVE,
        limit: "24",
        offset: String(Math.max(0, Math.min(4999, Number(p.offset) || 0))),
        rating: "pg-13",
        bundle: "messaging_non_clips",
      });
      if (p.accion === "buscar") {
        qs.set("q", String(p.q ?? "").slice(0, 50));
        qs.set("lang", "es");
      }
      const r = await fetch(`https://api.giphy.com/v1/gifs/${p.accion === "buscar" ? "search" : "trending"}?${qs}`);
      if (!r.ok) {
        return json({ error: r.status === 429 ? "Demasiadas búsquedas en esta hora. Espera un poco." : `GIPHY respondió ${r.status}` }, 502);
      }
      const datos = await r.json();
      const lista = (datos.data as Gif[] ?? []).map((g) => {
        const fija = g.images.fixed_width ?? {};
        const peq = g.images.fixed_width_small ?? fija;
        return {
          id: g.id,
          w: Number(fija.width) || 200,
          h: Number(fija.height) || 200,
          p: peq.webp || peq.url,   // vista previa
          f: fija.webp || fija.url, // la que se envía
        };
      }).filter((g) => g.p && g.f);
      const pag = datos.pagination ?? {};
      const mas = (pag.offset ?? 0) + (pag.count ?? 0) < (pag.total_count ?? 0);
      return json({ lista, mas });
    }

    if (p.accion === "archivo") {
      let url: URL;
      try { url = new URL(String(p.u)); } catch { return json({ error: "dirección no válida" }, 400); }
      if (url.protocol !== "https:" || !HOST_GIPHY.test(url.hostname)) return json({ error: "dirección no permitida" }, 400);
      const r = await fetch(url.toString());
      if (!r.ok || !r.body) return json({ error: `GIPHY respondió ${r.status}` }, 502);
      return new Response(r.body, {
        headers: { ...CORS, "Content-Type": r.headers.get("content-type") ?? "image/webp", "Cache-Control": "private, max-age=86400" },
      });
    }

    return json({ error: "acción desconocida" }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
