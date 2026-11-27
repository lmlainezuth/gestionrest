// Edge Function "ticketbai": guarda, firma (XAdES-EPES) y prepara el envío a la Hacienda Foral de
// Gipuzkoa. Desde la migración 0050 solo se firma y se envía lo que esta función guarda.
//
// Certificado de cada empresa: el que se sube desde la app (Ajustes › Programa), guardado cifrado
// en la base (migración 0054, ver ../_shared/certificado.ts). Mientras una empresa no lo haya
// pasado al almacén, el secreto antiguo TBAI_P12_<ID> / TBAI_P12_CLAVE_<ID>.
// Secretos necesarios (Supabase → Edge Functions → Secrets):
//   TBAI_CLAVE_MAESTRA   llave del almacén de certificados (32 bytes en base64)
//   PUENTE_SECRETO       el mismo que en Netlify (preparar_envio y resultado_envio)
// El certificado tiene que ser del NIF de la empresa: si no coincide, no se firma.
//
// Cuerpo: { accion: 'despertar' }                           → solo «ok»: la app la llama al abrir el cobro
//                                                             para que la función esté cargada al cobrar
//         { accion: 'probar' }                              → datos del certificado (admin o camarero)
//         { accion: 'registrar', fila, firmada }            → comprueba, firma si hace falta y GUARDA la
//                                                             factura; devuelve la fila guardada
//         { accion: 'firmar', xml }                         → firma una anulación (solo admin)
//         { accion: 'preparar_envio', tabla, id }           → (puente) certificado y fichero guardado
//         { accion: 'resultado_envio', tabla, id, … }       → (puente) apunta la respuesta de Hacienda
//         { accion: 'simular_envio', tabla, id }            → modo simulado: la deja como "simulada"
//         { accion: 'apartar', venta, motivo }              → deja en espera una venta sin internet
//                                                             que no se aceptó (migración 0052)
//         { accion: 'forzar', id, motivo }                  → (solo admin) guarda y deja lista para
//                                                             enviar una venta en espera, tal cual
import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2.50.3';
import forge from 'npm:node-forge@1.4.3';
import * as xadesjs from 'npm:xadesjs@3.0.0';
import * as xmlcore from 'npm:xml-core@3.0.0';
import { DOMImplementation, DOMParser, XMLSerializer } from 'npm:@xmldom/xmldom@0.9.12';
import { certificadoDelBar, certificadoDelNif, titularDe } from '../_shared/certificado.ts';

xadesjs.Application.setEngine('webcrypto', crypto);
xmlcore.setNodeDependencies({ DOMParser, XMLSerializer, DOMImplementation });

const POLITICA = {
  url: 'https://www.gipuzkoa.eus/ticketbai/sinadura',
  hash: '4LDJbY5hqHHHX858s9QV1P8yVGzo6H23P/iNRRv+PnQ=',
};
const QR = {
  pruebas: 'https://tbai.prep.gipuzkoa.eus/qr/',
  produccion: 'https://tbai.egoitza.gipuzkoa.eus/qr/',
};
const SERVICIO: Record<string, string> = { facturas: 'alta', anulaciones: 'baja', subsanaciones: 'zuzendu-alta' };
const TABLA: Record<string, string> = { facturas: 'facturas', anulaciones: 'tbai_anulaciones', subsanaciones: 'tbai_subsanaciones' };
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const json = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

// Rechazo de una factura que no cuadra: se dice por qué y queda en eventos_seguridad
class Rechazo extends Error {}

type Certificado = { key: CryptoKey; certBase64: string; titular: string; caduca: string };

async function leerCertificado(p12Base64: string, clave: string): Promise<Certificado> {
  const p12 = forge.pkcs12.pkcs12FromAsn1(forge.asn1.fromDer(forge.util.decode64(p12Base64)), clave);
  const oidClave = forge.pki.oids.pkcs8ShroudedKeyBag;
  const bolsa = p12.getBags({ bagType: oidClave })[oidClave] ?? p12.getBags({ bagType: forge.pki.oids.keyBag })[forge.pki.oids.keyBag];
  const clavePriv = bolsa![0].key as forge.pki.rsa.PrivateKey;
  const certs = p12.getBags({ bagType: forge.pki.oids.certBag })[forge.pki.oids.certBag]!.map((b) => b.cert!);
  const cert = certs.find((c) => (c.publicKey as forge.pki.rsa.PublicKey).n.equals(clavePriv.n)) ?? certs[0];
  const certDer = forge.asn1.toDer(forge.pki.certificateToAsn1(cert)).getBytes();
  const pkcs8 = forge.asn1.toDer(forge.pki.wrapRsaPrivateKey(forge.pki.privateKeyToAsn1(clavePriv))).getBytes();
  const key = await crypto.subtle.importKey(
    'pkcs8',
    Uint8Array.from(pkcs8, (ch) => ch.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  return {
    key,
    certBase64: forge.util.encode64(certDer),
    titular: titularDe(cert),
    caduca: cert.validity.notAfter.toISOString(),
  };
}

async function firmar(xmlSinFirma: string, cert: Certificado) {
  const doc = new DOMParser().parseFromString(xmlSinFirma, 'application/xml');
  const firmado = new xadesjs.SignedXml();
  await firmado.Sign({ name: 'RSASSA-PKCS1-v1_5' }, cert.key, doc as unknown as Document, {
    references: [{ id: 'Reference-TicketBai', uri: '', hash: 'SHA-256', transforms: ['enveloped'] }],
    x509: [cert.certBase64],
    signingCertificateV2: { certificate: cert.certBase64, digestAlgorithm: 'SHA-256' },
    signingTime: { value: new Date() },
    policy: { hash: 'SHA-256', digestValue: POLITICA.hash, identifier: { value: POLITICA.url } },
  });
  doc.documentElement!.appendChild(firmado.XmlSignature.GetXml() as unknown as Node);
  const xml = new XMLSerializer().serializeToString(doc);
  return { xml, signatureValue: valorFirma(xml)! };
}

// Solo el SignatureValue de la firma (ds:), no <SignatureValueFirmaFacturaAnterior> del encadenamiento
const valorFirma = (xml: string) =>
  xml.match(/<(?:\w+:)?SignatureValue(?:\s[^>]*)?>([^<]+)<\/(?:\w+:)?SignatureValue>/)?.[1].replace(/\s/g, '') ?? null;

// Firma hecha en un equipo con el certificado instalado: tiene que ser válida, una sola y del titular
async function comprobarFirmaEquipo(xml: string, nif: string): Promise<string> {
  const doc = new DOMParser().parseFromString(xml, 'application/xml');
  const firmas = doc.getElementsByTagNameNS('http://www.w3.org/2000/09/xmldsig#', 'Signature');
  if (firmas.length !== 1) throw new Rechazo('El fichero tiene que llevar una firma');
  const firmado = new xadesjs.SignedXml(doc as unknown as Document);
  firmado.LoadXml(firmas[0] as unknown as Element);
  if (!(await firmado.Verify())) throw new Rechazo('La firma del fichero no es válida');
  const x509 = doc.getElementsByTagNameNS('http://www.w3.org/2000/09/xmldsig#', 'X509Certificate')[0]?.textContent;
  if (!x509) throw new Rechazo('La firma no lleva certificado');
  const cert = forge.pki.certificateFromAsn1(forge.asn1.fromDer(forge.util.decode64(x509.replace(/\s/g, ''))));
  if (!certificadoDelNif(titularDe(cert), nif)) throw new Rechazo('El fichero no lo ha firmado el titular del bar');
  return valorFirma(xml)!;
}

// Lee la respuesta XML de Hacienda (Salida/Estado, CSV, ResultadosValidacion)
function leerRespuesta(xml: string) {
  const tag = (n: string) => xml.match(new RegExp(`<(?:\\w+:)?${n}>([\\s\\S]*?)</(?:\\w+:)?${n}>`))?.[1]?.trim() ?? null;
  const errores = [...xml.matchAll(/<(?:\w+:)?ResultadosValidacion>([\s\S]*?)<\/(?:\w+:)?ResultadosValidacion>/g)].map((m) => ({
    codigo: m[1].match(/<(?:\w+:)?Codigo>([^<]*)</)?.[1] ?? null,
    descripcion: m[1].match(/<(?:\w+:)?Descripcion>([^<]*)</)?.[1] ?? null,
  }));
  return { estado: tag('Estado'), descripcion: tag('Descripcion'), csv: tag('CSV'), fechaRecepcion: tag('FechaRecepcion'), errores };
}

// Estado y respuesta (como los guardaba la app hasta ahora) a partir de lo que devolvió Hacienda
function estadoDeRespuesta(http: number | null, texto: string | null, error: string | null) {
  if (error || texto == null) {
    return { estado: 'pendiente', respuesta: JSON.stringify({ descripcion: `No enviada todavía: ${error ?? 'sin respuesta'}` }) };
  }
  const r = leerRespuesta(texto);
  const descripcion = r.estado == null ? `Respuesta HTTP ${http}: ${texto.slice(0, 300)}` : r.descripcion;
  const respuesta = JSON.stringify({ estado: r.estado, descripcion, csv: r.csv, fecha: r.fechaRecepcion, avisos: r.errores });
  // Reenvío de algo que Hacienda ya tenía (se perdió la respuesta la primera vez): ya está recibido
  const yaRecibido = [r.descripcion, ...r.errores.map((e) => e.descripcion)]
    .some((t) => t != null && /ya (ha sido |fue )?recibid|duplicad/i.test(t));
  const estado = r.estado === '00' || (r.estado === '01' && yaRecibido) ? 'enviada' : r.estado === '01' ? 'error' : 'pendiente';
  return { estado, respuesta };
}

// Solo un fichero TicketBAI de ESTE titular: raíz conocida y NIF del emisor igual al de la empresa.
// Sin comentarios, CDATA ni DOCTYPE, que servirían para esconder otro emisor.
function comprobarXml(xml: unknown, nif: string, raices: string[]): string | null {
  if (typeof xml !== 'string' || xml.length === 0) return 'Falta el XML';
  if (xml.length > 200_000) return 'XML demasiado grande';
  if (/<!--|<!\[CDATA\[|<!DOCTYPE|<!ENTITY/i.test(xml)) return 'El XML lleva partes no admitidas';
  const raiz = xml.match(/^﻿?\s*(?:<\?xml[^>]*\?>\s*)?<(?:[\w.-]+:)?([\w.-]+)[\s>]/)?.[1];
  if (!raiz || !raices.includes(raiz)) return 'No es un fichero TicketBAI';
  const abiertos = xml.match(/<(?:[\w.-]+:)?Emisor[\s>]/g)?.length ?? 0;
  const emisores = [...xml.matchAll(/<(?:[\w.-]+:)?Emisor>\s*<(?:[\w.-]+:)?NIF>([^<]*)</g)].map((m) => m[1].trim().toUpperCase());
  if (emisores.length === 0 || emisores.length !== abiertos || emisores.some((e) => e !== nif)) {
    return 'El NIF del emisor del fichero no es el de la empresa';
  }
  return null;
}

// ---------- Lectura del fichero ----------

// deno-lint-ignore no-explicit-any
type Nodo = any;
const nombreLocal = (n: Nodo) => (n.localName ?? String(n.nodeName).split(':').pop()) as string;
const hijos = (el: Nodo, nombre: string): Nodo[] =>
  el ? Array.from(el.childNodes as ArrayLike<Nodo>).filter((n) => n.nodeType === 1 && nombreLocal(n) === nombre) : [];
const ruta = (el: Nodo, ...nombres: string[]): Nodo => nombres.reduce((e, n) => hijos(e, n)[0] ?? null, el);
const texto = (el: Nodo, ...nombres: string[]): string | null => ruta(el, ...nombres)?.textContent?.trim() ?? null;

// Fecha y hora como van en el fichero (hora de Gipuzkoa)
function enMadrid(d: Date) {
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/Madrid', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  }).formatToParts(d).map((x) => [x.type, x.value]));
  return { fecha: `${p.day}-${p.month}-${p.year}`, hora: `${p.hour}:${p.minute}:${p.second}`, ddmmaa: `${p.day}${p.month}${p.year.slice(2)}` };
}

// CRC-8 de TicketBAI (Anexo V): polinomio 0x07, init 0, 3 dígitos. Como lib/features/ticketbai/crc8.dart
function crc8(entrada: string) {
  let crc = 0;
  for (const byte of new TextEncoder().encode(entrada)) {
    crc ^= byte;
    for (let i = 0; i < 8; i++) crc = crc & 0x80 ? ((crc << 1) ^ 0x07) & 0xff : (crc << 1) & 0xff;
  }
  return String(crc).padStart(3, '0');
}

// Identificador TBAI y URL del QR. Como lib/features/ticketbai/tbai_codigos.dart
function codigos(nif: string, fecha: Date, firma: string, serie: string, numero: number, total: number, entorno: string) {
  const base = `TBAI-${nif}-${enMadrid(fecha).ddmmaa}-${firma.slice(0, 13)}-`;
  const id = base + crc8(base);
  const qrBase = entorno === 'produccion' ? QR.produccion : QR.pruebas;
  const sinCrc = `${qrBase}?id=${encodeURIComponent(id)}&s=${encodeURIComponent(serie)}&nf=${numero}&i=${total.toFixed(2)}`;
  return { id, qr: `${sinCrc}&cr=${crc8(sinCrc)}` };
}

const num = (v: unknown) => (v == null || v === '' ? NaN : Number(v));
const casi = (a: number, b: number, margen = 0.02) => Math.abs(a - b) <= margen;

// ---------- registrar: comprobar, firmar y guardar una factura ----------

type Contexto = {
  srv: SupabaseClient; supa: SupabaseClient; usuario: string; rol: string;
  config: { empresa_id: string; entorno: string; nif: string };
  cert: () => Promise<Certificado>;
  // Cronómetro de la función: cuánto tarda cada parte (se devuelve con la factura, solo tiempos)
  marca: (paso: string) => void;
};

// [forzado]: venta sin internet en espera que el administrador manda tal cual (acción forzar). Ya
// se emitió y el cliente tiene su ticket: no se comprueba la firma (la comprueba Hacienda) y, si no
// encaja en la cadena, se guarda "fuera de cadena". Lo demás (NIF, fichero = fila, pedido) igual.
async function registrar(cx: Contexto, fila: Record<string, unknown>, firmada: boolean,
                         forzado: { motivo: string; avisos: string[] } | null = null) {
  const { srv, supa, config } = cx;
  const nif = config.nif;
  const simulado = config.entorno !== 'pruebas' && config.entorno !== 'produccion';
  let rota = false;   // forzada fuera de cadena
  const romper = (motivo: string, error: Error) => {
    if (!forzado) throw error;
    rota = true;
    forzado.avisos.push(motivo);
  };

  const xml = String(fila.xml ?? '');
  const mal = comprobarXml(xml, nif, ['TicketBai']);
  if (mal) throw new Rechazo(mal);
  if (String(fila.nif_emisor ?? '').toUpperCase() !== nif) throw new Rechazo('El NIF del emisor no es el del bar');
  const doc = new DOMParser().parseFromString(xml, 'application/xml').documentElement;
  // La firma del equipo empieza a comprobarse ya, a la vez que las consultas (es lo que más cálculo lleva).
  // Antes, las comprobaciones del fichero: nada sin pasar por comprobarXml
  const firmaEquipo = !simulado && !forzado && firmada
    ? comprobarFirmaEquipo(xml, nif).then((v) => ({ v }), (e) => ({ e }))
    : null;

  // Consultas que no dependen unas de otras: todas a la vez desde el principio (antes iban una
  // detrás de otra). Se usan más abajo, en el mismo orden de comprobación que antes; la firma del equipo
  // se va comprobando mientras tanto.
  const cadenaPedida = String(fila.cadena ?? '');
  const [rYa, rUltimas, rUltimo, rPed, rOtra] = await Promise.all([
    typeof fila.id === 'string'
      ? srv.from('facturas').select().eq('id', fila.id).eq('empresa_id', config.empresa_id).maybeSingle()
      : Promise.resolve({ data: null }),
    supa.rpc('tbai_ultima_factura', { p_cadena: cadenaPedida }),
    supa.rpc('tbai_ultimo_numero', { p_serie: String(fila.serie ?? '') }),
    fila.pedido_id
      ? srv.from('pedidos').select('id, empresa_id, total').eq('id', fila.pedido_id).maybeSingle()
      : Promise.resolve({ data: null }),
    fila.pedido_id
      ? srv.from('facturas').select('id').eq('pedido_id', fila.pedido_id).limit(1)
      : Promise.resolve({ data: null }),
  ]);

  cx.marca('Consultas a la base (a la vez)');
  // Reintento de algo ya guardado (venta sin internet que se cortó al subir): se devuelve tal cual
  if (rYa.data) return rYa.data;

  // 1 · El fichero dice lo mismo que la fila
  const cab = ruta(doc, 'Factura', 'CabeceraFactura');
  const serie = String(fila.serie ?? '');
  const numero = num(fila.numero);
  const fecha = new Date(String(fila.fecha ?? ''));
  const total = num(fila.importe_total);
  if (!serie || !Number.isInteger(numero) || isNaN(fecha.getTime()) || isNaN(total)) throw new Rechazo('Faltan datos de la factura');
  const m = enMadrid(fecha);
  if (texto(cab, 'SerieFactura') !== serie || num(texto(cab, 'NumFactura')) !== numero) throw new Rechazo('Serie o número distintos en el fichero');
  if (texto(cab, 'FechaExpedicionFactura') !== m.fecha || texto(cab, 'HoraExpedicionFactura') !== m.hora) {
    throw new Rechazo('Fecha u hora distintas en el fichero');
  }
  const datos = ruta(doc, 'Factura', 'DatosFactura');
  if (!casi(num(texto(datos, 'ImporteTotalFactura')), total, 0.005)) throw new Rechazo('Importe distinto en el fichero');
  const detalles = hijos(ruta(datos, 'DetallesFactura'), 'IDDetalleFactura');
  if (!casi(detalles.reduce((s, d) => s + num(texto(d, 'ImporteTotal')), 0), total)) throw new Rechazo('Las líneas del fichero no suman el total');
  const lineas = Array.isArray(fila.lineas) ? fila.lineas as Record<string, unknown>[] : [];
  if (lineas.length !== detalles.length) throw new Rechazo('Líneas distintas en el fichero');
  if (!casi(lineas.reduce((s, l) => s + num(l.cantidad) * num(l.precio_unitario ?? l.precioUnitario), 0), total)) {
    throw new Rechazo('Las líneas no suman el total');
  }
  const destinatario = texto(doc, 'Sujetos', 'Destinatarios', 'IDDestinatario', 'NIF');
  if ((destinatario ?? null) !== (fila.cliente_nif ?? null)) throw new Rechazo('Destinatario distinto en el fichero');

  // 2 · Cadena y numeración: la de la base, no la que diga el equipo
  const cadena = cadenaPedida;
  if (!cadena || !serie.startsWith(cadena)) throw new Rechazo('Serie fuera de su cadena');
  const { data: ultimas, error: e1 } = rUltimas;
  if (e1) throw new Error(e1.message);
  const previa = (ultimas as Record<string, unknown>[] | null)?.[0] ?? null;
  const enc = ruta(doc, 'HuellaTBAI', 'EncadenamientoFacturaAnterior');
  if ((fila.anterior_id ?? null) !== (previa?.id ?? null)) {
    romper('no encadena con la última factura de la serie', Object.assign(new Error('La cadena ha cambiado'), { code: '23505' }));
  }
  if (previa && !rota) {
    const firmaPrevia = String(previa.firma ?? '');
    if (texto(enc, 'SerieFacturaAnterior') !== previa.serie || num(texto(enc, 'NumFacturaAnterior')) !== Number(previa.numero)
        || texto(enc, 'FechaExpedicionFacturaAnterior') !== enMadrid(new Date(String(previa.fecha))).fecha
        || texto(enc, 'SignatureValueFirmaFacturaAnterior') !== firmaPrevia.slice(0, 100)) {
      romper('el encadenamiento no es el de la factura anterior', new Rechazo('El encadenamiento del fichero no es el de la factura anterior'));
    }
    if (!forzado && fecha.getTime() < new Date(String(previa.fecha)).getTime() - 1000) throw new Rechazo('Fecha anterior a la de la factura previa');
  } else if (!previa && enc) {
    romper('encadena con una factura que no está guardada', new Rechazo('Encadenamiento con una factura que no existe'));
  }
  if (!forzado && fecha.getTime() > Date.now() + 5 * 60_000) throw new Rechazo('Fecha en el futuro');
  const { data: ultimo, error: e2 } = rUltimo;
  if (e2) throw new Error(e2.message);
  if (numero !== (Number(ultimo ?? 0) + 1)) {
    romper(`número ${numero} cuando tocaba el ${Number(ultimo ?? 0) + 1}`,
      Object.assign(new Error('La numeración ha cambiado'), { code: '23505' }));
  }

  // 3 · A qué corresponde: un pedido del bar sin factura, o la factura que rectifica o sustituye
  const sinConexion = fila.sin_conexion === true;
  if (fila.pedido_id) {
    const ped = rPed.data as { id: string; empresa_id: string; total: number } | null;
    if (!ped || ped.empresa_id !== config.empresa_id) throw new Rechazo('El pedido no es de este bar');
    const otra = rOtra.data as { id: string }[] | null;
    if (otra && otra.length > 0) throw new Rechazo('Este pedido ya tiene factura');
    if (!casi(Number(ped.total), total)) {
      // Venta sin internet ya firmada en el equipo: se guarda, pero queda apuntado
      if (!sinConexion && !forzado) throw new Rechazo(`El importe (${total}) no es el total del pedido (${ped.total})`);
      await apuntarEvento(srv, config.empresa_id, 'factura_descuadre', cx.usuario,
        `${serie}-${numero}: ${total} € en la venta sin internet; el pedido suma ${ped.total} €`);
    }
  } else if (fila.rectifica_id) {
    const { data: orig } = await srv.from('facturas').select('id, empresa_id, importe_total')
      .eq('id', fila.rectifica_id).maybeSingle();
    if (!orig || orig.empresa_id !== config.empresa_id) throw new Rechazo('La factura original no es de este bar');
    if (fila.rectificativa_codigo) {
      if (!(total < 0) || Math.abs(total) > Number(orig.importe_total) + 0.02) throw new Rechazo('La devolución supera la factura original');
    } else if (fila.sustituye_simplificada) {
      if (!casi(total, Number(orig.importe_total))) throw new Rechazo('La factura con NIF no tiene el importe del ticket');
    }
  } else if (cx.rol !== 'admin') {
    throw new Rechazo('Una factura sin pedido solo la hace el administrador');
  }

  // 4 · Firma: la del servidor, o la del equipo comprobada
  let xmlFinal = xml;
  let firma: string;
  if (simulado) {
    firma = String(fila.firma ?? valorFirma(xml) ?? '');
    if (!firma) throw new Rechazo('Falta la firma de prueba');
  } else if (forzado) {
    // Tal como se emitió: la firma la comprueba Hacienda al recibirla
    firma = valorFirma(xml) ?? '';
    if (!firma) throw new Rechazo('El fichero no lleva firma');
  } else if (firmaEquipo) {
    cx.marca('Comprobar el fichero');
    const r = await firmaEquipo;
    if ('e' in r) throw r.e;
    firma = r.v;
    cx.marca('Comprobar la firma (lo que faltaba)');
  } else {
    // <ds:Signature>, no <SignatureValueFirmaFacturaAnterior> del encadenamiento
    if (/<(?:[\w.-]+:)?Signature[\s>]/.test(xml)) throw new Rechazo('El fichero ya viene firmado');
    const cert = await cx.cert();
    if (!certificadoDelNif(cert.titular, nif)) throw new Rechazo('El certificado configurado no es del NIF de la empresa');
    const f = await firmar(xml, cert);
    xmlFinal = f.xml;
    firma = f.signatureValue;
  }
  const { id: tbaiId, qr } = codigos(nif, fecha, firma, serie, numero, total, config.entorno);

  // 5 · Guardar (la base vuelve a comprobar la cadena con su candado y la serie registrada)
  const permitidos = ['id', 'pedido_id', 'caja_id', 'serie', 'numero', 'fecha', 'tipo', 'cadena', 'anterior_id',
    'desglose_iva', 'cliente_nif', 'cliente_nombre', 'cliente_direccion', 'razon_social_emisor', 'lineas',
    'base_imponible', 'tipo_iva', 'cuota_iva', 'importe_total', 'rectifica_id', 'rectificativa_codigo',
    'sustituye_simplificada'];
  const nueva: Record<string, unknown> = Object.fromEntries(permitidos.filter((k) => fila[k] !== undefined).map((k) => [k, fila[k]]));
  Object.assign(nueva, {
    empresa_id: config.empresa_id,
    nif_emisor: nif,
    // Fuera de cadena: sin anterior en la base, pero con la referencia que lleva el fichero
    anterior_id: rota ? null : (previa?.id ?? null),
    fuera_de_cadena: rota,
    anterior_serie: rota ? texto(enc, 'SerieFacturaAnterior') : (previa?.serie ?? null),
    anterior_numero: rota ? (num(texto(enc, 'NumFacturaAnterior')) || null) : (previa?.numero ?? null),
    anterior_fecha: rota ? (fila.anterior_fecha ?? null) : (previa?.fecha ?? null),
    anterior_firma100: rota ? texto(enc, 'SignatureValueFirmaFacturaAnterior') : (previa ? String(previa.firma ?? '').slice(0, 100) : null),
    firma,
    tbai_id: tbaiId,
    qr_url: qr,
    xml: xmlFinal,
    creado_por: cx.usuario,
    legado: false,
    estado_envio: simulado ? 'simulada' : 'pendiente',
    respuesta_envio: simulado ? 'Modo simulado: no se envía a la Hacienda Foral' : null,
  });
  cx.marca('Preparar la fila');
  const { data, error } = await srv.from('facturas').insert(nueva).select().single();
  cx.marca('Guardar en la base');
  if (error) {
    if (error.code === '23505') throw Object.assign(new Error(error.message), { code: '23505' });
    throw new Rechazo(error.message);
  }
  return data;
}

// Compara un secreto sin que el tiempo de respuesta diga cuántos caracteres acertó
async function secretoIgual(dado: string | null, esperado: string | undefined): Promise<boolean> {
  if (!dado || !esperado) return false;
  const h = async (s: string) => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  const [a, b] = await Promise.all([h(dado), h(esperado)]);
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

// Apunta un intento sospechoso en eventos_seguridad (panel Seguridad y aviso diario). Si falla, sigue.
async function apuntarEvento(srv: SupabaseClient, empresa: string, tipo: string, usuario: string, detalle: string) {
  try {
    await srv.from('eventos_seguridad').insert({ empresa_id: empresa, tipo, usuario_id: usuario, detalle: detalle.slice(0, 500) });
  } catch (_) { /* sin aviso: no es crítico */ }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  // Cronómetro: [paso, milisegundos]. Solo tiempos, nunca datos
  const tiempos: [string, number][] = [];
  let tAnterior = performance.now();
  const marca = (paso: string) => {
    const t = performance.now();
    tiempos.push([paso, Math.round(t - tAnterior)]);
    tAnterior = t;
  };
  try {
    // Solo usuarios con sesión y de una empresa con TicketBAI configurado
    const supa = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    });
    const srv = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    // Sesión y cuerpo a la vez (cada viaje al servidor cuenta en el tiempo del cobro)
    const [{ data: usuario }, cuerpo] = await Promise.all([supa.auth.getUser(), req.json().catch(() => ({}))]);
    if (!usuario.user) return json({ error: 'Sin sesión' }, 401);
    marca('Comprobar la sesión');
    // Solo para que la función quede cargada mientras el camarero elige el importe: no hace nada más
    if (cuerpo?.accion === 'despertar') return json({ ok: true });
    // tbai_config solo devuelve la de la empresa actual del usuario (RLS por empresa). Firmar,
    // guardar, enviar y comprobar el certificado: solo quien cobra (nunca cocina). Las dos a la vez.
    const [{ data: config, error: errConfig }, { data: rol }] = await Promise.all([
      supa.from('tbai_config').select('empresa_id, entorno, nif').limit(1).single(),
      supa.rpc('mi_rol'),
    ]);
    if (errConfig || !config) return json({ error: 'No se pudo leer la configuración TicketBAI' }, 400);
    marca('Configuración y rol');
    const nif = String(config.nif ?? '').trim().toUpperCase();
    if (rol !== 'admin' && rol !== 'camarero') {
      return json({ error: 'Solo el administrador o un camarero pueden firmar y enviar facturas' }, 403);
    }

    // Certificado de ESTA empresa (cada bar puede tener un titular distinto), solo si hace falta
    let guardado: Awaited<ReturnType<typeof certificadoDelBar>> | undefined;
    const delBar = async () => {
      guardado ??= await certificadoDelBar(srv, String(config.empresa_id));
      if (!guardado) throw new Rechazo('Falta el certificado de esta empresa: el programador lo sube en Ajustes › Programa › Estado de los bares');
      return guardado;
    };
    let certificado: Certificado | null = null;
    const cert = async () => {
      const g = await delBar();
      return certificado ??= await leerCertificado(g.p12, g.clave);
    };
    const cx: Contexto = { srv, supa, usuario: usuario.user.id, rol: String(rol), config: { ...config, nif }, cert, marca };
    const puente = () => secretoIgual(req.headers.get('x-puente-secreto'), Deno.env.get('PUENTE_SECRETO'));

    if (cuerpo.accion === 'probar') {
      const c = await cert();
      if (!certificadoDelNif(c.titular, nif)) {
        return json({ error: `El certificado (${c.titular}) no es del NIF de la empresa (${nif || 'sin NIF'})` });
      }
      // La caducidad del certificado del servidor la apunta el servidor (aviso del panel, 0053)
      await srv.from('tbai_certificados').upsert({
        empresa_id: config.empresa_id, origen: 'servidor', titular: c.titular, caduca: c.caduca,
        actualizado_en: new Date().toISOString(),
      }, { onConflict: 'empresa_id,origen' });
      return json({ ok: true, titular: c.titular, caduca: c.caduca, entorno: config.entorno, origen: (await delBar()).origen });
    }

    if (cuerpo.accion === 'registrar') {
      try {
        const guardada = await registrar(cx, cuerpo.fila ?? {}, cuerpo.firmada === true);
        return json({ ...guardada, _tiempos: tiempos });
      } catch (e) {
        // deno-lint-ignore no-explicit-any
        if ((e as any).code === '23505') return json({ error: (e as Error).message, code: '23505' }, 409);
        if (e instanceof Rechazo) {
          await apuntarEvento(srv, config.empresa_id, 'factura_rechazada', usuario.user.id,
            `${cuerpo.fila?.serie ?? '?'}-${cuerpo.fila?.numero ?? '?'}: ${e.message}`);
          return json({ error: e.message }, 400);
        }
        throw e;
      }
    }

    if (cuerpo.accion === 'apartar') {
      // Venta sin internet que el servidor no aceptó: queda en espera con todo lo que trae el equipo
      const venta = cuerpo.venta;
      const factura = venta?.factura;
      if (!factura || typeof factura.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(factura.id)) return json({ error: 'Falta la venta' }, 400);
      if (JSON.stringify(venta).length > 600_000) return json({ error: 'Venta demasiado grande' }, 400);
      const mal = comprobarXml(factura.xml, nif, ['TicketBai']);
      if (mal) return json({ error: mal }, 400);
      const { data: ya } = await srv.from('facturas').select('id').eq('id', factura.id).eq('empresa_id', config.empresa_id).maybeSingle();
      if (ya) return json({ ok: true, resuelta: true });
      const { data: espera } = await srv.from('ventas_espera').select('id').eq('id', factura.id).maybeSingle();
      if (!espera) {
        const { error } = await srv.from('ventas_espera').insert({
          id: factura.id, empresa_id: config.empresa_id, usuario_id: usuario.user.id,
          serie: String(factura.serie ?? ''), numero: num(factura.numero) || 0, fecha: factura.fecha ?? null,
          importe: num(factura.importe_total) || null, motivo_rechazo: String(cuerpo.motivo ?? '').slice(0, 1000),
          venta, xml: factura.xml,
        });
        if (error && error.code !== '23505') return json({ error: error.message }, 400);
        await apuntarEvento(srv, config.empresa_id, 'venta_en_espera', usuario.user.id,
          `${factura.serie}-${factura.numero}: ${String(cuerpo.motivo ?? '')}`);
      }
      return json({ ok: true });
    }

    if (cuerpo.accion === 'forzar') {
      // Solo el administrador, con motivo, y queda en Seguridad
      if (rol !== 'admin') return json({ error: 'Solo el administrador puede enviar una venta en espera' }, 403);
      const motivo = String(cuerpo.motivo ?? '').trim();
      if (motivo.length < 10) return json({ error: 'Escribe el motivo (al menos 10 caracteres)' }, 400);
      const { data: espera } = await srv.from('ventas_espera').select()
        .eq('id', cuerpo.id).eq('empresa_id', config.empresa_id).maybeSingle();
      if (!espera) return json({ error: 'Esa venta no está en espera en este bar' }, 404);
      const { data: ya } = await srv.from('facturas').select().eq('id', espera.id).maybeSingle();
      if (ya) return json(ya);
      // Primero lo que la venta trae (puede que el equipo no llegara a subirlo): pedido, líneas,
      // cobros y cierre, sin repetir lo que ya esté
      const v = espera.venta;
      const emp = { empresa_id: config.empresa_id };
      const paso = async (q: PromiseLike<{ error: { message: string } | null }>, que: string) => {
        const { error } = await q;
        if (error) throw new Rechazo(`No se pudo guardar ${que}: ${error.message}`);
      };
      await paso(srv.from('pedidos').upsert({ ...v.pedido, ...emp }, { onConflict: 'id', ignoreDuplicates: true }), 'el pedido');
      if (Array.isArray(v.detalle) && v.detalle.length) {
        await paso(srv.from('pedido_detalle').upsert(v.detalle.map((d: Record<string, unknown>) => ({ ...d, ...emp, sin_conexion: true })),
          { onConflict: 'id', ignoreDuplicates: true }), 'las líneas');
      }
      if (Array.isArray(v.pagos) && v.pagos.length) {
        await paso(srv.from('pagos').upsert(v.pagos.map((p: Record<string, unknown>) => ({ ...p, ...emp })),
          { onConflict: 'id', ignoreDuplicates: true }), 'los cobros');
      }
      if (v.cierre) await paso(srv.from('pedidos').update(v.cierre).eq('id', v.pedido.id).neq('estado', 'pagado'), 'el cierre');
      if (v.mesa_id) await srv.from('mesas').update({ disponibilidad: 'libre' }).eq('id', v.mesa_id).eq('empresa_id', config.empresa_id);
      const forzado = { motivo, avisos: [] as string[] };
      try {
        const factura = await registrar(cx, { ...v.factura, id: espera.id }, true, forzado);
        await apuntarEvento(srv, config.empresa_id, 'factura_forzada', usuario.user.id,
          `${espera.serie}-${espera.numero}${forzado.avisos.length ? ` (${forzado.avisos.join('; ')})` : ''}: ${motivo}`);
        return json(factura);
      } catch (e) {
        if (e instanceof Rechazo) return json({ error: e.message }, 400);
        throw e;
      }
    }

    if (cuerpo.accion === 'simular_envio') {
      // Modo simulado: no se envía nada; queda como "simulada"
      if (config.entorno === 'pruebas' || config.entorno === 'produccion') return json({ error: 'No estás en modo simulado' }, 400);
      const tabla = TABLA[String(cuerpo.tabla)];
      if (!tabla || tabla === 'tbai_subsanaciones') return json({ error: 'Tabla no válida' }, 400);
      if (tabla !== 'facturas' && rol !== 'admin') return json({ error: 'Solo el administrador' }, 403);
      const respuesta = 'Modo simulado: no se envía a la Hacienda Foral';
      await srv.from(tabla).update({ estado_envio: 'simulada', respuesta_envio: respuesta })
        .eq('id', cuerpo.id).eq('empresa_id', config.empresa_id).eq('estado_envio', 'pendiente');
      return json({ estado: 'simulada', respuesta });
    }

    if (config.entorno !== 'pruebas' && config.entorno !== 'produccion') {
      return json({ error: `El entorno es "${config.entorno}": cámbialo a pruebas o producción` }, 400);
    }

    if (cuerpo.accion === 'firmar') {
      // Solo anulaciones, solo el administrador, y solo de una factura de este bar (las altas se
      // firman al guardarlas, con 'registrar')
      if (rol !== 'admin') {
        await apuntarEvento(srv, config.empresa_id, 'anulacion_denegada', usuario.user.id,
          `Rol ${rol}: intentó firmar un fichero`);
        return json({ error: 'Solo el administrador puede anular facturas' }, 403);
      }
      const mal = comprobarXml(cuerpo.xml, nif, ['AnulaTicketBai']);
      if (mal) return json({ error: mal }, 400);
      const doc = new DOMParser().parseFromString(cuerpo.xml as string, 'application/xml').documentElement;
      const cab = ruta(doc, 'IDFactura', 'CabeceraFactura');
      const { data: f } = await srv.from('facturas').select('id').eq('empresa_id', config.empresa_id)
        .eq('serie', texto(cab, 'SerieFactura') ?? '').eq('numero', num(texto(cab, 'NumFactura'))).maybeSingle();
      if (!f) return json({ error: 'Esa factura no es de este bar' }, 400);
      const c = await cert();
      if (!certificadoDelNif(c.titular, nif)) return json({ error: 'El certificado configurado no es del NIF de la empresa: no se firma' }, 400);
      const { xml, signatureValue } = await firmar(cuerpo.xml as string, c);
      return json({ ok: true, xmlFirmado: xml, signatureValue });
    }

    if (cuerpo.accion === 'preparar_envio' || cuerpo.accion === 'resultado_envio') {
      // Solo el servicio puente de Netlify (conoce el secreto compartido), en nombre del usuario
      if (!(await puente())) return json({ error: 'No autorizado' }, 403);
      const tabla = TABLA[String(cuerpo.tabla)];
      if (!tabla) return json({ error: 'Tabla no válida' }, 400);
      // Anular y subsanar en Hacienda: solo el administrador
      if (tabla !== 'facturas' && rol !== 'admin') return json({ error: 'Solo el administrador puede anular o subsanar facturas' }, 403);
      const { data: fila } = await srv.from(tabla).select('id, xml, estado_envio, factura_id:' + (tabla === 'facturas' ? 'id' : 'factura_id'))
        .eq('id', cuerpo.id).eq('empresa_id', config.empresa_id).maybeSingle();
      if (!fila) return json({ error: 'No está guardado en este bar' }, 404);

      if (cuerpo.accion === 'preparar_envio') {
        // Un solo equipo la envía a la vez (lo que hacía tbai_reclamar_envio)
        if (tabla !== 'tbai_subsanaciones') {
          const { data: mia } = await srv.from(tabla).update({ envio_intento: new Date().toISOString() })
            .eq('id', cuerpo.id).in('estado_envio', ['pendiente', 'error'])
            .or(`envio_intento.is.null,envio_intento.lt.${new Date(Date.now() - 120_000).toISOString()}`)
            .select('id');
          if (!mia || mia.length === 0) return json({ ocupada: true });
        } else if (fila.estado_envio !== 'pendiente') {
          return json({ ocupada: true });
        }
        const c = await cert();
        if (!certificadoDelNif(c.titular, nif)) return json({ error: 'El certificado configurado no es del NIF de la empresa' }, 400);
        const servicio = SERVICIO[String(cuerpo.tabla)];
        const raiz = { alta: 'TicketBai', baja: 'AnulaTicketBai', 'zuzendu-alta': 'SubsanacionModificacionTicketBAI' }[servicio]!;
        const mal = comprobarXml(fila.xml, nif, [raiz]);
        if (mal) return json({ error: mal }, 400);
        const g = await delBar();
        return json({ p12: g.p12, clave: g.clave, entorno: config.entorno, nif, xml: fila.xml, servicio });
      }

      // resultado_envio: el estado lo escribe el servidor con lo que respondió Hacienda
      const r = estadoDeRespuesta(cuerpo.http ?? null, cuerpo.respuesta ?? null, cuerpo.error ?? null);
      await srv.from(tabla).update({ estado_envio: r.estado, respuesta_envio: r.respuesta }).eq('id', fila.id);
      if (tabla === 'tbai_subsanaciones' && r.estado !== 'pendiente') {
        // La factura queda como recibida (subsanada) o sigue rechazada, con la respuesta nueva
        const respuesta = r.estado === 'enviada' ? JSON.stringify({ ...JSON.parse(r.respuesta), subsanada: true }) : r.respuesta;
        await srv.from('facturas').update({ estado_envio: r.estado, respuesta_envio: respuesta }).eq('id', fila.factura_id);
      }
      return json(r);
    }

    return json({ error: 'Acción desconocida' }, 400);
  } catch (e) {
    if (e instanceof Rechazo) return json({ error: e.message }, 400);
    return json({ error: `${e}` }, 500);
  }
});
