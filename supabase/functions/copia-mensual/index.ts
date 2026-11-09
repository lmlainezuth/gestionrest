// GestiónRest · copia de seguridad mensual en Google Drive.
// Guarda en un .zip las facturas (con su XML firmado), anulaciones, ventas, caja, gastos,
// fichajes, cuadrante, stock y registro de anulaciones del mes, y lo sube a
// Drive › "GestionRest - Copias" › <empresa>. Conservar: facturas 4-6 años, fichajes 4 años.
//
// La llaman:
//  · pg_cron el día 2 de cada mes (cabecera x-copia-secreto = secreto COPIA_SECRETO) → todas las empresas, mes anterior
//  · el administrador desde la app ("Hacer copia ahora") → su empresa; body {mes: "2026-10"} opcional
//
// Secretos: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN, COPIA_SECRETO
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";
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
function mesAnterior(): string {
  const hoy = new Date(new Date().toLocaleString("en-US", { timeZone: "Europe/Madrid" }));
  const d = new Date(hoy.getFullYear(), hoy.getMonth() - 1, 1);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
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

function csv(filas: any[], columnas: string[]): string {
  const esc = (v: unknown) => {
    if (v === null || v === undefined) return "";
    const s = typeof v === "object" ? JSON.stringify(v) : String(v);
    return /[";\n]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
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

async function carpeta(token: string, nombre: string, padre: string | null): Promise<string> {
  const id = await buscar(token, nombre, padre, true);
  if (id) return id;
  const j = await drive(token, "https://www.googleapis.com/drive/v3/files?fields=id", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ name: nombre, mimeType: "application/vnd.google-apps.folder", ...(padre ? { parents: [padre] } : {}) }),
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
    `ticketbai/*.xml     Facturas y anulaciones firmadas tal como se enviaron a Hacienda.`,
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
  for (const f of datos.facturas) zip.file(`ticketbai/facturas/${f.serie}-${f.numero}.xml`, f.xml ?? "");
  for (const a of datos.tbai_anulaciones) zip.file(`ticketbai/anulaciones/${a.factura_id}.xml`, a.xml ?? "");

  const bytes = await zip.generateAsync({ type: "uint8array", compression: "DEFLATE" });
  const raiz = await carpeta(token, "GestionRest - Copias", null);
  const dir = await carpeta(token, empresa.nombre, raiz);
  const nombre = `${empresa.nombre}_${mes}.zip`;
  const r = await subir(token, dir, nombre, bytes);
  return {
    archivo: nombre,
    enlace: r.webViewLink as string,
    bytes: bytes.length,
    detalle: `${datos.facturas.length} facturas, ${datos.gastos.length} gastos, ${datos.fichajes.length} fichajes`,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const cuerpo = await req.json().catch(() => ({}));
  const mes = /^\d{4}-\d{2}$/.test(cuerpo?.mes ?? "") ? cuerpo.mes as string : mesAnterior();

  // ¿Quién llama? pg_cron (secreto) → todas; administrador → la suya
  let empresas: { id: string; nombre: string }[];
  const secreto = Deno.env.get("COPIA_SECRETO");
  if (secreto && req.headers.get("x-copia-secreto") === secreto) {
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

  let token: string;
  try {
    token = await tokenGoogle();
  } catch (err) {
    const detalle = String((err as Error).message ?? err);
    for (const e of empresas) {
      await db.from("copias_seguridad").insert({ empresa_id: e.id, mes, estado: "error", detalle });
    }
    return json({ error: detalle }, 500);
  }

  const resultados = [];
  for (const e of empresas) {
    try {
      const r = await copiar(db, token, e, mes);
      await db.from("copias_seguridad").insert({ empresa_id: e.id, mes, estado: "ok", ...r });
      resultados.push({ empresa: e.nombre, ok: true, ...r });
    } catch (err) {
      const detalle = String((err as Error).message ?? err);
      await db.from("copias_seguridad").insert({ empresa_id: e.id, mes, estado: "error", detalle });
      resultados.push({ empresa: e.nombre, ok: false, detalle });
    }
  }
  return json({ mes, resultados });
});
