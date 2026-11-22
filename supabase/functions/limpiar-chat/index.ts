// Borra los mensajes del chat del equipo con más de 30 días, y sus fotos del almacenamiento.
// La llama la base de datos una vez por día (pg_cron) con el secreto compartido de Vault.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const DIAS = 30;
const MARCA = "/storage/v1/object/public/fotos/";

Deno.serve(async (req) => {
  try {
    const cfg = await sb.rpc("push_config");
    if (cfg.error || req.headers.get("x-secreto") !== cfg.data?.secreto) return new Response("no", { status: 401 });
    const limite = new Date(Date.now() - DIAS * 864e5).toISOString();
    let borrados = 0, fotos = 0;
    for (let vuelta = 0; vuelta < 20; vuelta++) {
      const r = await sb.from("chat_equipo").select("id,foto").lt("creado", limite).limit(500);
      if (r.error) throw new Error(r.error.message);
      if (!r.data.length) break;
      const rutas = r.data.map((m: any) => m.foto || "").filter((u: string) => u.includes(MARCA)).map((u: string) => decodeURIComponent(u.split(MARCA)[1].split("?")[0]));
      if (rutas.length) { const s = await sb.storage.from("fotos").remove(rutas); if (!s.error) fotos += rutas.length; }
      const d = await sb.from("chat_equipo").delete().in("id", r.data.map((m: any) => m.id));
      if (d.error) throw new Error(d.error.message);
      borrados += r.data.length;
    }
    return Response.json({ borrados, fotos, antes_de: limite });
  } catch (e: any) {
    return Response.json({ error: e.message }, { status: 500 });
  }
});
