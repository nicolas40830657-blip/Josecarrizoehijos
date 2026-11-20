// Envía notificaciones push cuando llega un mensaje, un pedido, una visita o un aviso de productos.
// La llama la base de datos (triggers) con un secreto compartido guardado en Vault.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
let cfg: Record<string, string> | null = null;

async function config() {
  if (cfg) return cfg;
  const r = await sb.rpc("push_config");
  if (r.error || !r.data) throw new Error("Sin configuración: " + r.error?.message);
  cfg = r.data;
  webpush.setVapidDetails("https://app.josecarrizoehijos.ar", cfg!.vapid_publica, cfg!.vapid_privada);
  return cfg!;
}

const peso = (n: number) => "$" + Math.round(+n || 0).toLocaleString("es-AR");
const primer = (s?: string | null) => (s || "").trim().split(/\s+/)[0] || "";
const corto = (s: string, n = 120) => (s.length > n ? s.slice(0, n - 1) + "…" : s);

async function uno(tabla: string, id: string, cols = "*") {
  const r = await sb.from(tabla).select(cols).eq("id", id).maybeSingle();
  return r.data as any;
}
async function equipoDe(c: any): Promise<string[]> {
  if (c.piletero_id) return [c.piletero_id];
  const r = await sb.from("perfiles").select("id").in("rol", ["coordinador", "administrador"]).eq("activo", true);
  return (r.data || []).map((x: any) => x.id);
}
const itemsTxt = (items: any[]) => (items || []).map((i) => `${i.nombre} ×${i.n}`).join(", ");

type Aviso = { usuarios: string[]; app: "equipo" | "cliente" | null; pref: string; title: string; body: string; url: string; tag: string };

async function armar(b: any): Promise<Aviso | null> {
  const { tabla, id, op, quien } = b;
  if (tabla === "prueba") {
    return { usuarios: [id], app: null, pref: "", title: "🔔 ¡Listo!", body: "Las notificaciones funcionan en este celular.", url: "", tag: "prueba" };
  }
  if (tabla === "mensajes") {
    const m = await uno("mensajes", id);
    if (!m) return null;
    const c = await uno("clientes", m.cliente_id);
    if (!c) return null;
    const body = m.texto ? corto(m.texto) : "📷 Te mandó una foto";
    if (m.de_cliente) {
      return { usuarios: await equipoDe(c), app: "equipo", pref: "mensajes", title: `💬 ${c.nombre}`, body, url: `index.html#chat=${c.id}`, tag: `chat-${c.id}` };
    }
    if (!c.usuario_id) return null;
    const a = m.autor_id ? await uno("perfiles", m.autor_id, "nombre") : null;
    return { usuarios: [c.usuario_id], app: "cliente", pref: "mensajes", title: `💬 ${primer(a?.nombre) || "Tu piletero"} te escribió`, body, url: "cliente.html#chat", tag: "chat" };
  }
  if (tabla === "pedidos") {
    const p = await uno("pedidos", id);
    if (!p) return null;
    const c = await uno("clientes", p.cliente_id);
    if (!c) return null;
    if (op === "INSERT") {
      return { usuarios: await equipoDe(c), app: "equipo", pref: "pedidos", title: `🛒 Pedido de ${c.nombre}`, body: corto(`${itemsTxt(p.items)} · ${peso(p.total)}`), url: `index.html#pedido=${p.id}`, tag: `pedido-${p.id}` };
    }
    if (p.estado === "cancelado" && quien && quien === c.usuario_id) {
      return { usuarios: await equipoDe(c), app: "equipo", pref: "pedidos", title: `${c.nombre} canceló su pedido`, body: corto(itemsTxt(p.items)), url: `index.html#pedido=${p.id}`, tag: `pedido-${p.id}` };
    }
    if (!c.usuario_id) return null;
    const pil = c.piletero_id ? await uno("perfiles", c.piletero_id, "nombre") : null, quienLleva = primer(pil?.nombre) || "Tu piletero";
    const t: Record<string, [string, string]> = {
      confirmado: ["✅ Tu pedido está confirmado", `${quienLleva} te lo lleva en la próxima visita.`],
      entregado: ["📦 Pedido entregado", corto(itemsTxt(p.items))],
      cancelado: ["Tu pedido se canceló", "Escribile a tu piletero si tenés dudas."],
    };
    if (!t[p.estado]) return null;
    return { usuarios: [c.usuario_id], app: "cliente", pref: "pedidos", title: t[p.estado][0], body: t[p.estado][1], url: "cliente.html#tienda", tag: `pedido-${p.id}` };
  }
  if (tabla === "realizadas") {
    const r = await uno("realizadas", id);
    if (!r) return null;
    const ayer = new Date(Date.now() - 36 * 3600e3).toISOString().slice(0, 10);
    if (r.fecha < ayer) return null; // cargas atrasadas: no avisar
    const c = await uno("clientes", r.cliente_id);
    if (!c?.usuario_id) return null;
    const pil = r.piletero_id ? await uno("perfiles", r.piletero_id, "nombre") : null;
    return { usuarios: [c.usuario_id], app: "cliente", pref: "visitas", title: `🏊 ${primer(pil?.nombre) || "Tu piletero"} ya pasó por tu pileta`, body: r.nota ? corto(r.nota) : "Mirá cómo quedó en la app.", url: "cliente.html#inicio", tag: "visita" };
  }
  if (tabla === "recomendaciones") {
    const r = await uno("recomendaciones", id);
    if (!r || r.estado !== "activa") return null;
    const c = await uno("clientes", r.cliente_id);
    if (!c?.usuario_id) return null;
    const act = await sb.from("recomendaciones").select("tipo,item_id,cantidad").eq("cliente_id", c.id).eq("estado", "activa");
    const nombres: string[] = [];
    for (const x of act.data || []) {
      const it = await uno(x.tipo === "k" ? "kits" : "productos", x.item_id, "nombre");
      if (it) nombres.push(`${it.nombre} ×${x.cantidad}`);
    }
    const a = r.autor_id ? await uno("perfiles", r.autor_id, "nombre") : null;
    return { usuarios: [c.usuario_id], app: "cliente", pref: "productos", title: "🧪 Te estás quedando sin productos", body: corto(`${primer(a?.nombre) || "Tu piletero"} te avisa: ${nombres.join(", ")}`), url: "cliente.html#inicio", tag: "recs" };
  }
  return null;
}

Deno.serve(async (req) => {
  try {
    const c = await config();
    if (req.headers.get("x-secreto") !== c.secreto) return new Response("no", { status: 401 });
    const b = await req.json();
    const a = await armar(b);
    if (!a || !a.usuarios.length) return Response.json({ enviados: 0 });
    let q = sb.from("push_subs").select().in("usuario_id", a.usuarios);
    if (a.app) q = q.eq("app", a.app);
    const subs = ((await q).data || []).filter((s: any) => !a.pref || s.prefs?.[a.pref] !== false);
    const payload = JSON.stringify({ title: a.title, body: a.body, url: a.url, tag: a.tag });
    let ok = 0;
    const errores: string[] = [];
    await Promise.all(subs.map(async (s: any) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "high" });
        ok++;
        await sb.from("push_subs").update({ usado: new Date().toISOString() }).eq("id", s.id);
      } catch (e: any) {
        errores.push(`${e.statusCode || ""} ${e.body || e.message}`.slice(0, 200));
        if (e.statusCode === 404 || e.statusCode === 410) await sb.from("push_subs").delete().eq("id", s.id);
      }
    }));
    return Response.json({ enviados: ok, de: subs.length, errores });
  } catch (e: any) {
    return Response.json({ error: e.message }, { status: 500 });
  }
});
