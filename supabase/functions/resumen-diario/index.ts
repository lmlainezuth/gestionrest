// GestiónRest · resumen diario por correo (lo vendido, caja, anulaciones, avisos y reservas de hoy).
// "Día del bar": de 06:00 a 06:00 (hora de Madrid), para contar lo vendido pasada la medianoche.
//
// La llaman: pg_cron cada mañana (cabecera x-copia-secreto) → todas las empresas con correo_resumen;
//            el administrador desde la app ("Enviar prueba") → la suya.
// Secretos: RESEND_API_KEY, RESUMEN_SECRETO (el de su cron, cabecera x-copia-secreto); opcional
// RESUMEN_DE ("Bar Itsasoa <avisos@tudominio.com>")
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.50.3";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-copia-secreto",
};
const json = (c: unknown, s = 200) =>
  new Response(JSON.stringify(c), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

// Compara un secreto sin que el tiempo de respuesta diga cuántos caracteres acertó
async function secretoIgual(dado: string | null, esperado: string | undefined): Promise<boolean> {
  if (!dado || !esperado) return false;
  const h = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([h(dado), h(esperado)]);
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

const eur = (v: number) => v.toLocaleString("es-ES", { style: "currency", currency: "EUR" });
const esc = (s: unknown) => String(s ?? "").replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
const DIAS = ["domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado"];

function offsetMadrid(d: Date): string {
  const s = new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Madrid", timeZoneName: "longOffset" })
    .formatToParts(d).find((p) => p.type === "timeZoneName")!.value;
  return s === "GMT" ? "+00:00" : s.replace("GMT", "");
}
/** Fecha (yyyy-mm-dd) de Madrid con desplazamiento de días. */
function fechaMadrid(desplazar = 0): string {
  const d = new Date(Date.now() + desplazar * 86400000);
  return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Madrid" }).format(d);
}
const seisDe = (fecha: string) => `${fecha}T06:00:00${offsetMadrid(new Date(`${fecha}T12:00:00Z`))}`;
const hora = (iso: string) =>
  new Intl.DateTimeFormat("es-ES", { timeZone: "Europe/Madrid", hour: "2-digit", minute: "2-digit" }).format(new Date(iso));

async function resumen(db: SupabaseClient, e: { id: string; nombre: string }) {
  const ayer = fechaMadrid(-1), hoy = fechaMadrid(0);
  const semAyer = fechaMadrid(-8), semHoy = fechaMadrid(-7);
  const [d0, d1, s0, s1] = [seisDe(ayer), seisDe(hoy), seisDe(semAyer), seisDe(semHoy)];
  const n = (v: unknown) => Number(v ?? 0);

  const [ventas, ventasSem, pagos, cierres, anul, errores, stock, reservas, equipo] = await Promise.all([
    db.from("pedidos").select("total").eq("empresa_id", e.id).eq("estado", "pagado").gte("pagado_en", d0).lt("pagado_en", d1),
    db.from("pedidos").select("total").eq("empresa_id", e.id).eq("estado", "pagado").gte("pagado_en", s0).lt("pagado_en", s1),
    db.from("pagos").select("metodo, importe").eq("empresa_id", e.id).gte("creado_en", d0).lt("creado_en", d1),
    db.from("turnos_caja").select("diferencia, tarjeta_diferencia, cerrado_por, cerrado_en").eq("empresa_id", e.id)
      .eq("estado", "cerrado").gte("cerrado_en", d0).lt("cerrado_en", d1),
    db.from("registro_anulaciones").select("tipo, descripcion, importe, usuario_id, momento, motivo").eq("empresa_id", e.id)
      .gte("momento", d0).lt("momento", d1).order("momento"),
    db.from("facturas").select("id", { count: "exact", head: true }).eq("empresa_id", e.id).eq("estado_envio", "error"),
    db.from("articulos_stock").select("nombre, stock, minimo, unidad").eq("empresa_id", e.id).eq("activo", true),
    db.from("reservas").select("hora, nombre, personas, nota").eq("empresa_id", e.id).eq("fecha", hoy)
      .eq("estado", "confirmada").order("hora"),
    db.from("empresa_usuarios").select("usuario_id, perfiles(nombre)").eq("empresa_id", e.id),
  ]);
  const nombre = new Map((equipo.data ?? []).map((u: any) => [u.usuario_id, u.perfiles?.nombre ?? "¿?"]));
  const total = (ventas.data ?? []).reduce((s, p: any) => s + n(p.total), 0);
  const totalSem = (ventasSem.data ?? []).reduce((s, p: any) => s + n(p.total), 0);
  const tickets = ventas.data?.length ?? 0;
  const metodos: Record<string, number> = {};
  for (const p of pagos.data ?? []) metodos[(p as any).metodo] = (metodos[(p as any).metodo] ?? 0) + n((p as any).importe);
  const pct = totalSem > 0 ? Math.round(((total - totalSem) / totalSem) * 100) : null;
  const anulaciones = anul.data ?? [];
  const importeAnul = anulaciones.reduce((s, a: any) => s + n(a.importe), 0);
  const bajos = (stock.data ?? []).filter((a: any) => n(a.minimo) > 0 && n(a.stock) <= n(a.minimo));
  const diaSemana = DIAS[new Date(`${ayer}T12:00:00Z`).getUTCDay()];

  const avisos: string[] = [];
  for (const c of cierres.data ?? []) {
    const d = n((c as any).diferencia);
    if (Math.abs(d) >= 1) avisos.push(`Caja: ${d < 0 ? "faltan" : "sobran"} <b>${eur(Math.abs(d))}</b> en el cierre de ${esc(nombre.get((c as any).cerrado_por))} (${hora((c as any).cerrado_en)})`);
    const t = (c as any).tarjeta_diferencia;
    if (t !== null && Math.abs(n(t)) >= 1) avisos.push(`Datáfono: diferencia de <b>${eur(n(t))}</b>`);
  }
  if ((errores.count ?? 0) > 0) avisos.push(`TicketBAI: <b>${errores.count}</b> facturas rechazadas por Hacienda — revisar`);
  if (anulaciones.length >= 5 || importeAnul >= 30) avisos.push(`Muchas anulaciones: ${anulaciones.length} por ${eur(importeAnul)}`);
  if (bajos.length) avisos.push(`Stock bajo mínimo: ${bajos.map((a: any) => esc(a.nombre)).join(", ")}`);

  const fila = (a: string, b: string) => `<tr><td style="padding:4px 12px 4px 0;color:#5E5A52">${a}</td><td style="padding:4px 0;text-align:right;font-weight:600">${b}</td></tr>`;
  const html = `
<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;color:#1C1B19">
  <h2 style="margin:0 0 4px">${esc(e.nombre)} · ${diaSemana} ${ayer.slice(8)}/${ayer.slice(5, 7)}</h2>
  <div style="background:#0F5C4D;color:#fff;border-radius:14px;padding:18px;margin:12px 0">
    <div style="opacity:.8">Vendido</div>
    <div style="font-size:34px;font-weight:700">${eur(total)}</div>
    <div>${pct === null ? `El ${diaSemana} anterior: ${eur(totalSem)}` : `${pct >= 0 ? "▲" : "▼"} ${Math.abs(pct)} % frente al ${diaSemana} anterior (${eur(totalSem)})`}</div>
  </div>
  <table style="width:100%;border-collapse:collapse">
    ${fila("Tickets", `${tickets}${tickets ? ` · medio ${eur(total / tickets)}` : ""}`)}
    ${fila("Efectivo", eur(metodos.efectivo ?? 0))}
    ${fila("Tarjeta", eur(metodos.tarjeta ?? 0))}
    ${metodos.credito ? fila("A cuenta", eur(metodos.credito)) : ""}
    ${fila("Anulaciones", `${anulaciones.length} · ${eur(importeAnul)}`)}
  </table>
  <h3 style="margin:18px 0 6px">Avisos</h3>
  ${avisos.length ? `<ul style="padding-left:18px">${avisos.map((a) => `<li style="margin-bottom:4px">${a}</li>`).join("")}</ul>` : `<p style="color:#0F5C4D">✔ Todo en orden</p>`}
  ${anulaciones.length ? `<h3 style="margin:18px 0 6px">Anulaciones</h3><ul style="padding-left:18px;color:#5E5A52">${anulaciones.map((a: any) =>
    `<li>${hora(a.momento)} · ${esc(nombre.get(a.usuario_id) ?? "Sistema")} · ${esc(a.descripcion)} · ${eur(n(a.importe))}${a.motivo ? ` · “${esc(a.motivo)}”` : ""}</li>`).join("")}</ul>` : ""}
  <h3 style="margin:18px 0 6px">Reservas de hoy</h3>
  ${(reservas.data ?? []).length ? `<ul style="padding-left:18px">${(reservas.data ?? []).map((r: any) =>
    `<li>${String(r.hora).slice(0, 5)} · ${esc(r.nombre)} · ${r.personas} pers.${r.nota ? ` · ${esc(r.nota)}` : ""}</li>`).join("")}</ul>` : `<p style="color:#5E5A52">Ninguna</p>`}
  <p style="color:#9a958b;font-size:12px;margin-top:24px">GestiónRest · día contado de 06:00 a 06:00</p>
</div>`;
  return { asunto: `${e.nombre}: ${eur(total)} el ${diaSemana}${avisos.length ? ` · ${avisos.length} avisos` : ""}`, html };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  let empresas: { id: string; nombre: string; correo_resumen: string | null }[];
  if (await secretoIgual(req.headers.get("x-copia-secreto"), Deno.env.get("RESUMEN_SECRETO"))) {
    const { data } = await db.from("empresa").select("id, nombre, correo_resumen").not("correo_resumen", "is", null);
    empresas = data ?? [];
  } else {
    const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: { user } } = await db.auth.getUser(jwt);
    if (!user) return json({ error: "No has iniciado sesión" }, 401);
    const { data: perfil } = await db.from("perfiles").select("empresa_actual").eq("id", user.id).single();
    const { data: yo } = await db.from("empresa_usuarios").select("rol, activo")
      .eq("empresa_id", perfil?.empresa_actual).eq("usuario_id", user.id).maybeSingle();
    if (yo?.rol !== "admin" || !yo.activo) return json({ error: "Solo el administrador" }, 403);
    const { data } = await db.from("empresa").select("id, nombre, correo_resumen")
      .eq("id", perfil!.empresa_actual).single();
    if (!data?.correo_resumen) return json({ error: "Pon antes el correo del resumen" }, 400);
    // El envío lo paga y lo firma la plataforma: a mano, como mucho uno cada 10 minutos por bar. La
    // espera la guarda el servidor (migración 0053): el administrador no la puede borrar, y dos
    // peticiones a la vez no pasan las dos
    const { data: puede, error: errLimite } = await db.rpc("reclamar_accion_manual",
      { p_empresa: data.id, p_accion: "resumen", p_minutos: 10 });
    if (errLimite) return json({ error: errLimite.message }, 500);
    if (puede !== true) return json({ error: "Ya se envió un resumen hace poco: espera unos minutos" }, 429);
    empresas = [data];
  }

  const clave = Deno.env.get("RESEND_API_KEY");
  if (!clave) return json({ error: "Falta el secreto RESEND_API_KEY" }, 500);
  const resultados = [];
  for (const e of empresas) {
    try {
      const { asunto, html } = await resumen(db, e);
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${clave}`, "Content-Type": "application/json" },
        body: JSON.stringify({
          from: Deno.env.get("RESUMEN_DE") ?? "GestionRest <onboarding@resend.dev>",
          // Como mucho 5 direcciones válidas (el resto se ignora)
          to: e.correo_resumen!.split(",").map((s) => s.trim())
            .filter((s) => /^[^\s@,<>"]+@[^\s@,<>"]+\.[^\s@,<>"]+$/.test(s)).slice(0, 5),
          subject: asunto,
          html,
        }),
      });
      const j = await r.json();
      resultados.push(r.ok ? { empresa: e.nombre, ok: true } : { empresa: e.nombre, ok: false, detalle: j.message ?? r.status });
    } catch (err) {
      resultados.push({ empresa: e.nombre, ok: false, detalle: String((err as Error).message ?? err) });
    }
  }
  return json({ resultados });
});
