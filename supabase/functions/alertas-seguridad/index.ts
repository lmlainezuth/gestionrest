// GestiónRest · aviso diario de seguridad para la plataforma (todos los bares).
// Mira las últimas 24 horas de eventos_seguridad, del registro de control y de las copias, y manda
// un correo a AVISOS_CORREO SOLO si hay algo que mirar (con {"siempre": true} lo manda igualmente,
// para probar). La llama pg_cron cada mañana con la cabecera x-copia-secreto (secreto COPIA_SECRETO).
//
// Secretos: SUPABASE_SERVICE_ROLE_KEY, COPIA_SECRETO, RESEND_API_KEY, AVISOS_CORREO, RESUMEN_DE.
// Desplegar con: supabase functions deploy alertas-seguridad --no-verify-jwt
import { createClient } from "npm:@supabase/supabase-js@2.50.3";

const json = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { "Content-Type": "application/json" } });

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
};

Deno.serve(async (req) => {
  const secreto = Deno.env.get("COPIA_SECRETO");
  if (!secreto || req.headers.get("x-copia-secreto") !== secreto) return json({ error: "No autorizado" }, 403);
  const siempre = (await req.json().catch(() => ({})))?.siempre === true;

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const desde = new Date(Date.now() - 24 * 3600 * 1000).toISOString();

  const [{ data: empresas }, { data: eventos }, { data: control }, { data: copias }] = await Promise.all([
    db.from("empresa").select("id, nombre"),
    db.from("eventos_seguridad").select("empresa_id, tipo, usuario_id").gte("momento", desde).limit(20000),
    db.from("registro_anulaciones").select("empresa_id, tipo, importe")
      .gte("momento", desde).in("tipo", ["cobro_fuera_turno", "venta_anulada", "linea_borrada"]).limit(20000),
    db.from("copias_seguridad").select("empresa_id, estado, detalle").gte("creado_en", desde).eq("estado", "error"),
  ]);
  const nombre = new Map((empresas ?? []).map((e) => [e.id as string, e.nombre as string]));
  const bar = (id: string | null) => (id ? nombre.get(id) ?? id : "sin bar");

  const lineas: string[] = [];

  // PIN: muchos fallos de una misma persona o bloqueos
  const porPersona = new Map<string, { empresa: string; fallidos: number; bloqueos: number }>();
  for (const e of eventos ?? []) {
    if (e.tipo !== "pin_fallido" && e.tipo !== "pin_bloqueado") continue;
    const k = `${e.empresa_id}|${e.usuario_id}`;
    const v = porPersona.get(k) ?? { empresa: e.empresa_id, fallidos: 0, bloqueos: 0 };
    if (e.tipo === "pin_fallido") v.fallidos++; else v.bloqueos++;
    porPersona.set(k, v);
  }
  const ids = [...new Set([...porPersona.keys()].map((k) => k.split("|")[1]))];
  const { data: perfiles } = ids.length
    ? await db.from("perfiles").select("id, nombre").in("id", ids)
    : { data: [] as { id: string; nombre: string }[] };
  const persona = new Map((perfiles ?? []).map((p) => [p.id as string, p.nombre as string]));
  for (const [k, v] of porPersona) {
    if (v.fallidos >= PIN_FALLIDOS_POR_PERSONA || v.bloqueos > 0) {
      lineas.push(`· ${bar(v.empresa)} · ${persona.get(k.split("|")[1]) ?? "?"}: ${v.fallidos} PIN incorrectos, ${v.bloqueos} bloqueos`);
    }
  }

  // Otros eventos: cualquiera es para mirar
  const otros = new Map<string, number>();
  for (const e of eventos ?? []) {
    if (e.tipo === "pin_fallido" || e.tipo === "pin_bloqueado") continue;
    const k = `${e.empresa_id}|${e.tipo}`;
    otros.set(k, (otros.get(k) ?? 0) + 1);
  }
  for (const [k, n] of otros) {
    const [empresa, tipo] = k.split("|");
    lineas.push(`· ${bar(empresa)}: ${n} ${NOMBRES[tipo] ?? tipo}`);
  }

  // Registro de control: cobros en turnos cerrados, ventas anuladas y productos borrados
  const resumen = new Map<string, { n: number; importe: number }>();
  for (const a of control ?? []) {
    const k = `${a.empresa_id}|${a.tipo}`;
    const v = resumen.get(k) ?? { n: 0, importe: 0 };
    v.n++;
    v.importe += Number(a.importe ?? 0);
    resumen.set(k, v);
  }
  const textoControl: Record<string, string> = {
    cobro_fuera_turno: "cobros en un turno ya cerrado",
    venta_anulada: "ventas cobradas anuladas",
    linea_borrada: "productos borrados",
  };
  for (const [k, v] of resumen) {
    const [empresa, tipo] = k.split("|");
    lineas.push(`· ${bar(empresa)}: ${v.n} ${textoControl[tipo] ?? tipo} (${v.importe.toFixed(2)} €)`);
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
