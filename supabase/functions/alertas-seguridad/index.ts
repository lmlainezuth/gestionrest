// GestiónRest · aviso diario de seguridad para la plataforma (todos los bares).
// Mira las últimas 24 horas de eventos_seguridad, del registro de control y de las copias, y manda
// un correo a AVISOS_CORREO SOLO si hay algo que mirar (con {"siempre": true} lo manda igualmente,
// para probar). La llama pg_cron cada mañana con la cabecera x-copia-secreto (secreto ALERTAS_SECRETO).
// Los totales los cuenta la base (alertas_resumen, migración 0053): sin límite de filas de la API.
//
// Secretos: SUPABASE_SERVICE_ROLE_KEY, ALERTAS_SECRETO, RESEND_API_KEY, AVISOS_CORREO, RESUMEN_DE.
// Desplegar con: supabase functions deploy alertas-seguridad --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2.50.3";

// Compara un secreto sin que el tiempo de respuesta diga cuántos caracteres acertó
async function secretoIgual(dado: string | null, esperado: string | undefined): Promise<boolean> {
  if (!dado || !esperado) return false;
  const h = async (s: string) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([h(dado), h(esperado)]);
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

// Llamada del cron con la cabecera x-copia-secreto: "ok" si el secreto coincide, el motivo si no
// (sin enseñar el secreto), null si no trae la cabecera. Sin espacios ni saltos de línea de más.
async function secretoCron(req: Request, nombre: string): Promise<"ok" | string | null> {
  const dado = req.headers.get("x-copia-secreto")?.trim();
  if (!dado) return null;
  const esperado = Deno.env.get(nombre)?.trim();
  if (!esperado) return `No autorizado: falta ${nombre} en el servidor`;
  return (await secretoIgual(dado, esperado)) ? "ok" : "No autorizado: el secreto no coincide";
}

// CORS: el botón Test del panel de Supabase llama desde el navegador, que antes pregunta con OPTIONS
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-copia-secreto",
};
const json = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...cors, "Content-Type": "application/json" } });

// Umbrales: a partir de aquí se avisa
const PIN_FALLIDOS_POR_PERSONA = 10;
const NOMBRES: Record<string, string> = {
  pin_fallido: "PIN incorrectos",
  pin_bloqueado: "bloqueos por PIN",
  anulacion_denegada: "anulaciones de factura intentadas sin ser administrador",
  usuario_ajeno: "intentos de cambiar el PIN de un usuario de otro bar",
  pin_otro_bar: "PIN que no se pudieron cambiar (usuario en otro bar)",
  pin_bloqueado_bar: "bloqueos de la entrada con PIN en todo el bar",
  pin_cambiado: "cambios de PIN",
  precio_distinto: "ventas sin internet con un precio distinto del de la carta",
  fondo_distinto: "aperturas de caja con un fondo distinto del que se dejó",
  factura_rechazada: "facturas que el servidor no aceptó (no cuadraban)",
  factura_descuadre: "ventas sin internet que no cuadran con su pedido",
  pin_admin_denegado: "intentos de cambiar el PIN de otro administrador",
  miembro_cambiado: "cambios de rol, permisos o bajas de empleados",
  venta_en_espera: "ventas sin internet que el servidor no aceptó (quedan en espera)",
  factura_forzada: "ventas en espera enviadas tal cual por el administrador (factura forzada)",
  usuario_creado: "altas de usuarios",
  altas_limitadas: "altas de usuarios frenadas por el tope (más de 10 en una hora)",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const cron = await secretoCron(req, "ALERTAS_SECRETO");
  if (cron !== "ok") return json({ error: cron ?? "No autorizado: no llega la cabecera x-copia-secreto" }, 403);
  const siempre = (await req.json().catch(() => ({})))?.siempre === true;

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();

  const [{ data: empresas }, { data: cuentas, error: errCuentas }, { data: copias }] = await Promise.all([
    db.from("empresa").select("id, nombre"),
    db.rpc("alertas_resumen", { p_desde: desde }),
    db.from("copias_seguridad").select("empresa_id, estado, detalle").gte("creado_en", desde).eq("estado", "error"),
  ]);
  if (errCuentas) return json({ error: errCuentas.message }, 500);
  const nombre = new Map((empresas ?? []).map((e) => [e.id as string, e.nombre as string]));
  const bar = (id: string | null) => (id ? nombre.get(id) ?? id : "sin bar");
  type Pin = { empresa_id: string; usuario_id: string | null; nombre: string | null; fallidos: number; bloqueos: number };
  type Otro = { empresa_id: string; tipo: string; n: number };
  type Control = { empresa_id: string; tipo: string; n: number; importe: number };
  const resumen = (cuentas ?? {}) as { pin?: Pin[]; otros?: Otro[]; control?: Control[] };

  const lineas: string[] = [];

  // PIN: muchos fallos de una misma persona o bloqueos
  for (const v of resumen.pin ?? []) {
    if (v.fallidos >= PIN_FALLIDOS_POR_PERSONA || v.bloqueos > 0) {
      lineas.push(`· ${bar(v.empresa_id)} · ${v.nombre ?? "?"}: ${v.fallidos} PIN incorrectos, ${v.bloqueos} bloqueos`);
    }
  }

  // Otros eventos: cualquiera es para mirar
  for (const o of resumen.otros ?? []) lineas.push(`· ${bar(o.empresa_id)}: ${o.n} ${NOMBRES[o.tipo] ?? o.tipo}`);

  // Registro de control: cobros en turnos cerrados, ventas anuladas y productos borrados
  const textoControl: Record<string, string> = {
    cobro_fuera_turno: "cobros en un turno ya cerrado",
    venta_anulada: "ventas cobradas anuladas",
    linea_borrada: "productos borrados",
  };
  for (const c of resumen.control ?? []) {
    lineas.push(`· ${bar(c.empresa_id)}: ${c.n} ${textoControl[c.tipo] ?? c.tipo} (${Number(c.importe).toFixed(2)} €)`);
  }

  // Ventas sin internet en espera y aún sin resolver (sean del día que sean)
  const { data: espera } = await db.from("ventas_espera").select("id, empresa_id, serie, numero, creado_en").limit(1000);
  if (espera && espera.length > 0) {
    const { data: hechas } = await db.from("facturas").select("id").in("id", espera.map((e) => e.id));
    const resueltas = new Set((hechas ?? []).map((f) => f.id as string));
    const porBar = new Map<string, string[]>();
    for (const e of espera.filter((e) => !resueltas.has(e.id as string))) {
      porBar.set(e.empresa_id, [...(porBar.get(e.empresa_id) ?? []), `${e.serie}-${e.numero}`]);
    }
    for (const [empresa, ventas] of porBar) {
      lineas.push(`· ${bar(empresa)}: ${ventas.length} venta${ventas.length === 1 ? "" : "s"} sin internet en espera ` +
        `(${ventas.slice(0, 5).join(", ")}${ventas.length > 5 ? "…" : ""}): Facturas › Ventas en espera`);
    }
  }

  // Copias en Drive que fallaron
  for (const c of copias ?? []) lineas.push(`· ${bar(c.empresa_id)}: falló la copia en Drive (${c.detalle ?? ""})`);

  // Cuentas creadas en las últimas 24 horas que no son de ningún bar (ni programadores): con el
  // registro abierto en Supabase, cualquiera puede crearse una
  try {
    const { data: usuarios } = await db.auth.admin.listUsers({ perPage: 1000 });
    const nuevos = (usuarios?.users ?? []).filter((u) => u.created_at >= desde);
    if (nuevos.length) {
      const ids = nuevos.map((u) => u.id);
      const [{ data: miembros }, { data: progs }] = await Promise.all([
        db.from("empresa_usuarios").select("usuario_id").in("usuario_id", ids),
        db.from("programadores").select("usuario_id").in("usuario_id", ids),
      ]);
      const conBar = new Set([...(miembros ?? []), ...(progs ?? [])].map((m) => m.usuario_id as string));
      for (const u of nuevos.filter((u) => !conBar.has(u.id))) {
        lineas.push(`· Cuenta nueva sin ningún bar: ${u.email ?? u.id} (revisa que el registro abierto esté desactivado)`);
      }
    }
  } catch (_) { /* si falla, el resto del aviso sigue */ }

  if (lineas.length === 0 && !siempre) return json({ ok: true, avisos: 0 });

  const clave = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
  const para = (Deno.env.get("AVISOS_CORREO") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!clave || para.length === 0) return json({ error: "Faltan RESEND_API_KEY o AVISOS_CORREO" }, 500);
  const texto = [
    "Resumen de seguridad de GestiónRest (últimas 24 horas):",
    "",
    ...(lineas.length ? lineas : ["Nada fuera de lo normal."]),
    "",
    "Detalle de cada bar: GestiónRest › Números › Seguridad (como administrador de ese bar).",
    "Fuera de la app: Supabase › Logs (Auth y Edge Functions) para intentos desde fuera.",
  ].join("\n");
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${clave}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: Deno.env.get("RESUMEN_DE") ?? "GestionRest <onboarding@resend.dev>",
      to: para,
      subject: lineas.length ? `GestiónRest: ${lineas.length} avisos de seguridad` : "GestiónRest: sin avisos de seguridad",
      text: texto,
    }),
  });
  return json({ ok: r.ok, avisos: lineas.length });
});
