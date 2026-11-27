// GestiónRest · copia de seguridad en Google Drive (un zip por empresa y mes).
// Guarda en un .zip las facturas (con su XML firmado y la respuesta de Hacienda), anulaciones,
// subsanaciones, ventas, caja, gastos, fichajes, cuadrante, stock y registro de anulaciones del
// mes, y lo sube a Drive › "GestionRest - Copias" › "<id> · <nombre>" › copia_<mes>.zip (si ya
// existe, lo sustituye). La carpeta se busca por el id del bar (appProperties.empresa), no por el
// nombre. Conservar: facturas 4-6 años, fichajes 4 años.
//
// La llaman:
//  · pg_cron TODOS LOS DÍAS (cabecera x-copia-secreto = secreto COPIA_SECRETO) → todas las
//    empresas, mes en curso; los días 1 y 2 también el mes anterior, para cerrarlo completo.
//    Si algo falla, correo a AVISOS_CORREO (si están RESEND_API_KEY y AVISOS_CORREO).
//  · el administrador desde la app ("Hacer copia ahora") → su empresa, igual; body {mes: "2026-10"} opcional
//
// Secretos: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN, COPIA_SECRETO;
// para el aviso: RESEND_API_KEY, AVISOS_CORREO (tu correo; con el remitente de pruebas de Resend
// solo llega al correo de tu cuenta de Resend) y opcional RESUMEN_DE.
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2.50.3";
import JSZip from "npm:jszip@3.10.1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-copia-secreto",
};
const json = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), { status: estado, headers: { ...cors, "Content-Type": "application/json" } });

// ---------- Fechas en hora de Madrid ----------
function offsetMadrid(d: Date): string {
  const s = new Intl.DateTimeFormat("en-US", { timeZone: "Europe/Madrid", timeZoneName: "longOffset" })
    .formatToParts(d).find((p) => p.type === "timeZoneName")!.value; // "GMT+01:00"
  return s === "GMT" ? "+00:00" : s.replace("GMT", "");
}
function inicioMes(anio: number, mes: number): string {
  const aprox = new Date(Date.UTC(anio, mes - 1, 1, 12));
  return `${anio}-${String(mes).padStart(2, "0")}-01T00:00:00${offsetMadrid(aprox)}`;
}
function hoyMadrid(): Date {
  return new Date(new Date().toLocaleString("en-US", { timeZone: "Europe/Madrid" }));
}
function textoMes(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
}
/** Mes en curso y, los días 1 y 2, también el anterior (para que quede completo). */
function mesesACopiar(): string[] {
  const hoy = hoyMadrid();
  const actual = textoMes(hoy);
  if (hoy.getDate() > 2) return [actual];
  return [textoMes(new Date(hoy.getFullYear(), hoy.getMonth() - 1, 1)), actual];
}

// ---------- Lectura completa (Supabase corta en 1000 filas) ----------
async function todo(q: () => any): Promise<any[]> {
  const filas: any[] = [];
  for (let i = 0; ; i += 1000) {
    const { data, error } = await q().range(i, i + 999);
    if (error) throw new Error(error.message);
    filas.push(...data);
    if (data.length < 1000) return filas;
  }
}

/** Para tablas de migraciones recientes (0025, 0026): si aún no existen, la copia sigue. */
async function siExiste(p: Promise<any[]>): Promise<any[]> {
  try {
    return await p;
  } catch (e) {
    if (/schema cache|does not exist/i.test(String((e as Error).message ?? e))) return [];
    throw e;
  }
}

function csv(filas: any[], columnas: string[]): string {
  const esc = (v: unknown) => {
    if (v === null || v === undefined) return "";
    let s = typeof v === "object" ? JSON.stringify(v) : String(v);
    // Texto que Excel tomaría como fórmula (=, +, -, @, tabulador o retorno al principio): se le
    // antepone un apóstrofo. Los números se quedan como están.
    if (typeof v === "string" && /^[=+\-@\t\r]/.test(s)) s = `'${s}`;
    return /[";\n\r\t]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
  };
  // Separador ; y BOM para que Excel en español lo abra bien
  return "﻿" + [columnas.join(";"), ...filas.map((f) => columnas.map((c) => esc(f[c])).join(";"))].join("\n");
}

// ---------- Google Drive ----------
async function tokenGoogle(): Promise<string> {
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      // trim(): un espacio o salto de línea al pegar el secreto basta para que Google lo rechace
      client_id: (Deno.env.get("GOOGLE_CLIENT_ID") ?? "").trim(),
      client_secret: (Deno.env.get("GOOGLE_CLIENT_SECRET") ?? "").trim(),
      refresh_token: (Deno.env.get("GOOGLE_REFRESH_TOKEN") ?? "").trim(),
      grant_type: "refresh_token",
    }),
  });
  const j = await r.json();
  if (!r.ok) {
    const pista: Record<string, string> = {
      invalid_grant: "refresh token no válido o caducado: sácalo de nuevo en OAuth Playground (con tus credenciales en el engranaje)",
      invalid_client: "ID o secreto del cliente mal copiados",
      unauthorized_client: "el refresh token es de otro cliente: sácalo con TU ID y secreto",
    };
    throw new Error(`Google no da acceso (${j.error}): ${pista[j.error] ?? j.error_description ?? ""}`);
  }
  return j.access_token;
}

async function drive(token: string, url: string, init: RequestInit = {}) {
  const r = await fetch(url, { ...init, headers: { Authorization: `Bearer ${token}`, ...(init.headers ?? {}) } });
  const j = await r.json();
  if (!r.ok) throw new Error(`Drive: ${j.error?.message ?? r.status}`);
  return j;
}

const comillas = (s: string) => s.replaceAll("\\", "\\\\").replaceAll("'", "\\'");

async function buscar(token: string, nombre: string, padre: string | null, carpeta: boolean): Promise<string | null> {
  const q = [`name='${comillas(nombre)}'`, "trashed=false",
    carpeta ? "mimeType='application/vnd.google-apps.folder'" : "mimeType!='application/vnd.google-apps.folder'",
    ...(padre ? [`'${padre}' in parents`] : [])].join(" and ");
  const j = await drive(token, `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(q)}&fields=files(id)`);
  return j.files?.[0]?.id ?? null;
}

/** Carpeta por nombre o, si se da [empresa], por la marca appProperties.empresa (el nombre puede cambiar). */
async function carpeta(token: string, nombre: string, padre: string | null, empresa?: string): Promise<string> {
  let id: string | null;
  if (empresa) {
    const q = [`appProperties has { key='empresa' and value='${comillas(empresa)}' }`, "trashed=false",
      "mimeType='application/vnd.google-apps.folder'", ...(padre ? [`'${padre}' in parents`] : [])].join(" and ");
    const j = await drive(token, `https://www.googleapis.com/drive/v3/files?q=${encodeURIComponent(q)}&fields=files(id)`);
    id = j.files?.[0]?.id ?? null;
  } else {
    id = await buscar(token, nombre, padre, true);
  }
  if (id) return id;
  const j = await drive(token, "https://www.googleapis.com/drive/v3/files?fields=id", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      name: nombre, mimeType: "application/vnd.google-apps.folder",
      ...(padre ? { parents: [padre] } : {}),
      ...(empresa ? { appProperties: { empresa } } : {}),
    }),
  });
  return j.id;
}

/** Sube (o sustituye si ya existe con el mismo nombre) y devuelve {id, webViewLink}. */
async function subir(token: string, padre: string, nombre: string, datos: Uint8Array) {
  let id = await buscar(token, nombre, padre, false);
  if (!id) {
    id = (await drive(token, "https://www.googleapis.com/drive/v3/files?fields=id", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: nombre, parents: [padre], mimeType: "application/zip" }),
    })).id;
  }
  return await drive(token, `https://www.googleapis.com/upload/drive/v3/files/${id}?uploadType=media&fields=id,webViewLink,size`, {
    method: "PATCH",
    headers: { "Content-Type": "application/zip" },
    body: datos,
  });
}

// ---------- Copia de una empresa ----------
async function copiar(db: SupabaseClient, token: string, empresa: { id: string; nombre: string }, mes: string) {
  const [anio, m] = mes.split("-").map(Number);
  const desde = inicioMes(anio, m);
  const hasta = inicioMes(m === 12 ? anio + 1 : anio, m === 12 ? 1 : m + 1);
  const diaDesde = `${mes}-01`;
  const diaHasta = new Date(Date.UTC(anio, m, 0)).toISOString().slice(0, 10);
  const e = empresa.id;

  const porFecha = (tabla: string, col: string, orden = col) =>
    todo(() => db.from(tabla).select("*").eq("empresa_id", e).gte(col, desde).lt(col, hasta).order(orden));
  const porDia = (tabla: string, col: string) =>
    todo(() => db.from(tabla).select("*").eq("empresa_id", e).gte(col, diaDesde).lte(col, diaHasta).order(col));
  const maestro = (tabla: string, campos = "*") => todo(() => db.from(tabla).select(campos).eq("empresa_id", e).order("id"));

  const datos: Record<string, any[]> = {
    facturas: await porFecha("facturas", "fecha"),
    tbai_anulaciones: await porFecha("tbai_anulaciones", "fecha"),
    tbai_subsanaciones: await siExiste(porFecha("tbai_subsanaciones", "fecha")),
    pedidos: await porFecha("pedidos", "creado_en"),
    pedido_detalle: await porFecha("pedido_detalle", "creado_en"),
    pagos: await porFecha("pagos", "creado_en"),
    turnos_caja: await porFecha("turnos_caja", "abierto_en"),
    movimientos_caja: await porFecha("movimientos_caja", "creado_en"),
    gastos: await porDia("gastos", "fecha"),
    cajas_diarias: await porDia("cajas_diarias", "fecha"),
    fichajes: await porFecha("fichajes", "momento"),
    cuadrante: await porDia("cuadrante", "fecha"),
    movimientos_stock: await porFecha("movimientos_stock", "creado_en"),
    registro_anulaciones: await porFecha("registro_anulaciones", "momento"),
    // Foto de los maestros a final de mes
    productos: await maestro("productos"),
    grupos_productos: await maestro("grupos_productos"),
    proveedores: await maestro("proveedores"),
    clientes: await maestro("clientes"),
    articulos_stock: await maestro("articulos_stock"),
    empresa_tbai: await maestro("tbai_config", "nif, razon_social, entorno, licencia_tbai, nif_desarrollador, nombre_software, version_software"),
    series: await siExiste(maestro("tbai_series")),
  };
  const equipo = await todo(() =>
    db.from("empresa_usuarios").select("usuario_id, rol, activo, perfiles(nombre)").eq("empresa_id", e).order("usuario_id"));
  datos.equipo = equipo.map((u: any) => ({ id: u.usuario_id, nombre: u.perfiles?.nombre, rol: u.rol, activo: u.activo }));

  const zip = new JSZip();
  zip.file("LEEME.txt", [
    `Copia de seguridad de GestiónRest`,
    `Empresa: ${empresa.nombre}`,
    `Mes: ${mes} (hora de Madrid)`,
    `Hecha: ${new Date().toISOString()}`,
    ``,
    `datos/*.json        Todas las tablas del mes, completas (para restaurar).`,
    `*.csv               Lo mismo en tabla, para abrir con Excel (separador ;).`,
    `ticketbai/          Ficheros TicketBAI tal como se enviaron a Hacienda, por serie-número:`,
    `  facturas/         SERIE-NUMERO.xml (firmado) y SERIE-NUMERO.respuesta.json (lo que contestó Hacienda)`,
    `  anulaciones/      SERIE-NUMERO.xml de la factura anulada y su respuesta`,
    `  subsanaciones/    SERIE-NUMERO_FECHA.xml (Zuzendu) y su respuesta`,
    ``,
    `Conservar: facturas 4-6 años (Hacienda), registro de jornada 4 años (art. 34.9 ET).`,
  ].join("\r\n"));
  for (const [t, filas] of Object.entries(datos)) zip.file(`datos/${t}.json`, JSON.stringify(filas, null, 1));
  zip.file("facturas.csv", csv(datos.facturas, ["serie", "numero", "fecha", "tipo", "cliente_nif", "cliente_nombre",
    "base_imponible", "cuota_iva", "importe_total", "tbai_id", "estado_envio"]));
  zip.file("gastos.csv", csv(datos.gastos, ["fecha", "concepto", "importe", "categoria", "iva_tipo", "iva_importe", "estado"]));
  zip.file("caja_diaria.csv", csv(datos.cajas_diarias, ["fecha", "total", "efectivo", "tarjeta", "estado", "notas"]));
  zip.file("fichajes.csv", csv(datos.fichajes, ["nombre", "tipo", "momento", "origen", "motivo", "registrado_en"]));
  zip.file("anulaciones.csv", csv(datos.registro_anulaciones, ["momento", "tipo", "descripcion", "cantidad", "importe", "mesa", "motivo"]));
  // Serie y número de las facturas anuladas o subsanadas (pueden ser de un mes anterior)
  const numeros = new Map<string, string>(datos.facturas.map((f) => [f.id, `${f.serie}-${f.numero}`]));
  const faltan = [...new Set([...datos.tbai_anulaciones, ...datos.tbai_subsanaciones]
    .map((x) => x.factura_id as string).filter((id) => !numeros.has(id)))];
  for (let i = 0; i < faltan.length; i += 100) {
    const { data, error } = await db.from("facturas").select("id, serie, numero").in("id", faltan.slice(i, i + 100));
    if (error) throw new Error(error.message);
    for (const f of data ?? []) numeros.set(f.id, `${f.serie}-${f.numero}`);
  }
  const respuesta = (texto: string | null) => {
    if (!texto) return null;
    try {
      return JSON.stringify(JSON.parse(texto), null, 1);
    } catch (_) {
      return texto;
    }
  };
  const ficheros = (carpeta: string, nombre: string, x: any) => {
    zip.file(`ticketbai/${carpeta}/${nombre}.xml`, x.xml ?? "");
    const r = respuesta(x.respuesta_envio);
    if (r) zip.file(`ticketbai/${carpeta}/${nombre}.respuesta.json`, r);
  };
  for (const f of datos.facturas) ficheros("facturas", `${f.serie}-${f.numero}`, f);
  for (const a of datos.tbai_anulaciones) ficheros("anulaciones", numeros.get(a.factura_id) ?? a.factura_id, a);
  for (const s of datos.tbai_subsanaciones) {
    const cuando = String(s.fecha).replace(/[^0-9]/g, "").slice(0, 14);
    ficheros("subsanaciones", `${numeros.get(s.factura_id) ?? s.factura_id}_${cuando}`, s);
  }

  const bytes = await zip.generateAsync({ type: "uint8array", compression: "DEFLATE" });
  const raiz = await carpeta(token, "GestionRest - Copias", null);
  // La carpeta va por el id del bar, que no cambia ni se repite: dos bares con el mismo nombre (o uno
  // que se cambie el nombre) ya no pisan la copia de otro. Las copias anteriores siguen en su carpeta antigua.
  const dir = await carpeta(token, `${empresa.id} · ${empresa.nombre.replace(/[\\'\/]/g, " ").slice(0, 60)}`, raiz, empresa.id);
  const nombre = `copia_${mes}.zip`;
  const r = await subir(token, dir, nombre, bytes);
  return {
    archivo: nombre,
    enlace: r.webViewLink as string,
    bytes: bytes.length,
    detalle: `${datos.facturas.length} facturas, ${datos.gastos.length} gastos, ${datos.fichajes.length} fichajes`,
  };
}

// ---------- Aviso por correo si la copia automática falla ----------
async function avisarFallo(fallos: { empresa: string; mes: string; detalle: string }[]) {
  const clave = (Deno.env.get("RESEND_API_KEY") ?? "").trim();
  const para = (Deno.env.get("AVISOS_CORREO") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!clave || para.length === 0 || fallos.length === 0) return;
  const texto = [
    "La copia automática de GestiónRest en Google Drive ha fallado:",
    "",
    ...fallos.map((f) => `· ${f.empresa} (${f.mes}): ${f.detalle}`),
    "",
    "Mañana se vuelve a intentar sola. Si sigue fallando, mira el panel de GestiónRest o los",
    "registros de la función copia-mensual en Supabase.",
  ].join("\n");
  try {
    await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${clave}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: Deno.env.get("RESUMEN_DE") ?? "GestionRest <onboarding@resend.dev>",
        to: para,
        subject: `GestiónRest: falló la copia en Drive (${fallos.length})`,
        text: texto,
      }),
    });
  } catch (_) {
    // Si tampoco sale el correo, queda el aviso del panel (copias_seguridad)
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const cuerpo = await req.json().catch(() => ({}));
  const mesPedido = /^\d{4}-(0[1-9]|1[0-2])$/.test(cuerpo?.mes ?? "") ? cuerpo.mes as string : null;

  // ¿Quién llama? pg_cron (secreto) → todas; administrador → la suya
  let empresas: { id: string; nombre: string }[];
  const secreto = Deno.env.get("COPIA_SECRETO");
  const automatica = !!secreto && req.headers.get("x-copia-secreto") === secreto;
  if (automatica) {
    const { data } = await db.from("empresa").select("id, nombre");
    empresas = data ?? [];
  } else {
    const jwt = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: { user } } = await db.auth.getUser(jwt);
    if (!user) return json({ error: "No has iniciado sesión" }, 401);
    const { data: perfil } = await db.from("perfiles").select("empresa_actual").eq("id", user.id).single();
    const { data: yo } = await db.from("empresa_usuarios").select("rol, activo")
      .eq("empresa_id", perfil?.empresa_actual).eq("usuario_id", user.id).maybeSingle();
    if (yo?.rol !== "admin" || !yo.activo) return json({ error: "Solo el administrador puede hacer copias" }, 403);
    const { data } = await db.from("empresa").select("id, nombre").eq("id", perfil!.empresa_actual).single();
    empresas = data ? [data] : [];
  }
  // Un administrador solo rehace el mes en curso o el anterior: los cerrados no se reescriben a mano
  // (y no se llena la cuenta de Drive compartida con meses inventados)
  const hoy = hoyMadrid();
  const recientes = [textoMes(hoy), textoMes(new Date(hoy.getFullYear(), hoy.getMonth() - 1, 1))];
  const meses = mesPedido && (automatica || recientes.includes(mesPedido)) ? [mesPedido] : mesesACopiar();

  let token: string;
  try {
    token = await tokenGoogle();
  } catch (err) {
    const detalle = String((err as Error).message ?? err);
    for (const e of empresas) {
      await db.from("copias_seguridad").insert({ empresa_id: e.id, mes: meses.at(-1), estado: "error", detalle });
    }
    if (automatica) await avisarFallo(empresas.map((e) => ({ empresa: e.nombre, mes: meses.join(", "), detalle })));
    return json({ error: detalle }, 500);
  }

  const resultados = [];
  for (const mes of meses) {
    for (const e of empresas) {
      try {
        const r = await copiar(db, token, e, mes);
        await db.from("copias_seguridad").insert({ empresa_id: e.id, mes, estado: "ok", ...r });
        resultados.push({ empresa: e.nombre, mes, ok: true, ...r });
      } catch (err) {
        const detalle = String((err as Error).message ?? err);
        await db.from("copias_seguridad").insert({ empresa_id: e.id, mes, estado: "error", detalle });
        resultados.push({ empresa: e.nombre, mes, ok: false, detalle });
      }
    }
  }
  if (automatica) {
    await avisarFallo(resultados.filter((r) => !r.ok).map((r) => ({ empresa: r.empresa, mes: r.mes, detalle: String(r.detalle) })));
  }
  return json({ meses, resultados });
});
