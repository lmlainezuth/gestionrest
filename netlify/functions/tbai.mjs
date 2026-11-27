// Servicio puente TicketBAI (Netlify Functions, Node).
// Envía a la Hacienda Foral de Gipuzkoa un XML YA FIRMADO por la Edge Function "ticketbai".
// Existe porque Hacienda pide el certificado con una renegociación TLS que Flutter (BoringSSL)
// y el servidor de Supabase no admiten; Node (OpenSSL) sí.
//
// Variables de entorno en Netlify (Site configuration → Environment variables):
//   SUPABASE_URL       https://zouujjameuyyedqiotxt.supabase.co
//   SUPABASE_ANON_KEY  la publishable key (la misma de lib/core/config.dart)
//   PUENTE_SECRETO     una contraseña larga inventada; la misma en los secretos de Supabase
import https from 'node:https';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (cuerpo, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

// En memoria mientras la función siga caliente, POR SESIÓN: cada usuario trabaja en una
// empresa y cada empresa tiene su certificado (nunca se mezcla el de otra)
const certificados = new Map();
// El rol y la pertenencia al bar se vuelven a comprobar cada pocos minutos: quien deja de ser
// camarero o administrador no sigue enviando con el certificado hasta que caduque su sesión
const VIDA_CACHE_MS = 5 * 60 * 1000;

async function leerCertificado(auth) {
  const guardado = certificados.get(auth);
  if (guardado && Date.now() - guardado.leido < VIDA_CACHE_MS) return guardado;
  certificados.delete(auth);
  const r = await fetch(`${process.env.SUPABASE_URL}/functions/v1/ticketbai`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: process.env.SUPABASE_ANON_KEY,
      Authorization: auth,
      'x-puente-secreto': process.env.PUENTE_SECRETO ?? '',
    },
    body: JSON.stringify({ accion: 'certificado' }),
  });
  const d = await r.json();
  if (!d.p12) throw new Error(d.error ?? 'No se pudo obtener el certificado');
  // entorno: el configurado en el bar (undefined si la función "ticketbai" aún no lo devuelve)
  const certificado = {
    pfx: Buffer.from(d.p12, 'base64'), passphrase: d.clave ?? '', entorno: d.entorno,
    nif: String(d.nif ?? '').trim().toUpperCase(), rol: d.rol, leido: Date.now(),
  };
  if (certificados.size > 100) certificados.clear();
  certificados.set(auth, certificado);
  return certificado;
}

// Cada servicio de Hacienda recibe su fichero y solo el de ESTE titular: raíz conocida y NIF del
// emisor igual al de la empresa. Sin comentarios, CDATA ni DOCTYPE, que servirían para esconder otro emisor.
const RAIZ = { alta: 'TicketBai', baja: 'AnulaTicketBai', 'zuzendu-alta': 'SubsanacionModificacionTicketBAI' };

function comprobarXml(xml, nif, raizEsperada) {
  if (typeof xml !== 'string' || xml.length === 0) return 'Falta el XML';
  if (xml.length > 200_000) return 'XML demasiado grande';
  if (/<!--|<!\[CDATA\[|<!DOCTYPE|<!ENTITY/i.test(xml)) return 'El XML lleva partes no admitidas';
  const raiz = xml.match(/^﻿?\s*(?:<\?xml[^>]*\?>\s*)?<(?:[\w.-]+:)?([\w.-]+)[\s>]/)?.[1];
  if (raiz !== raizEsperada) return 'El fichero no es el que corresponde a este servicio';
  const abiertos = xml.match(/<(?:[\w.-]+:)?Emisor[\s>]/g)?.length ?? 0;
  const emisores = [...xml.matchAll(/<(?:[\w.-]+:)?Emisor>\s*<(?:[\w.-]+:)?NIF>([^<]*)</g)].map((m) => m[1].trim().toUpperCase());
  if (emisores.length === 0 || emisores.length !== abiertos || emisores.some((e) => e !== nif)) {
    return 'El NIF del emisor del fichero no es el de la empresa';
  }
  return null;
}

function enviar(host, path, xml, cert) {
  const body = Buffer.from(xml, 'utf8');
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        host,
        path,
        method: 'POST',
        pfx: cert.pfx,
        passphrase: cert.passphrase,
        headers: { 'Content-Type': 'application/xml;charset=UTF-8', 'Content-Length': body.length },
        timeout: 30000,
      },
      (res) => {
        let texto = '';
        res.setEncoding('utf8');
        res.on('data', (c) => (texto += c));
        res.on('end', () => resolve({ http: res.statusCode, respuesta: texto }));
      },
    );
    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error('Hacienda no responde (30 s)')));
    req.end(body);
  });
}

export default async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Solo POST' }, 405);
  // Fuera del try: si algo falla solo se olvida el certificado de ESTA sesión
  const auth = req.headers.get('authorization') ?? '';
  try {
    // Solo usuarios con sesión en GestiónRest
    const u = await fetch(`${process.env.SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: process.env.SUPABASE_ANON_KEY, Authorization: auth },
    });
    if (!u.ok) return json({ error: 'Sin sesión' }, 401);

    const { xmlFirmado, entorno, baja, servicio } = await req.json();
    if (!xmlFirmado || !String(xmlFirmado).includes('SignatureValue')) return json({ error: 'Falta el XML firmado' }, 400);
    let cert = await leerCertificado(auth);
    // El entorno es el configurado en el bar, no el que diga la app. Si no coinciden, se vuelve a
    // leer (el bar pudo pasar a producción con la función caliente) y, si sigue sin coincidir, no se envía
    if (cert.entorno && cert.entorno !== entorno) {
      certificados.delete(auth);
      cert = await leerCertificado(auth);
      if (cert.entorno && cert.entorno !== entorno) {
        return json({ error: `El entorno pedido (${entorno}) no es el configurado en el bar (${cert.entorno})` }, 400);
      }
    }
    const host = (cert.entorno ?? entorno) === 'produccion' ? 'tbai-z.egoitza.gipuzkoa.eus' : 'tbai-z.prep.gipuzkoa.eus';
    // servicio: alta, baja o zuzendu-alta (subsanación). Las apps antiguas solo mandan "baja"
    const ruta = ['alta', 'baja', 'zuzendu-alta'].includes(servicio) ? servicio : baja ? 'baja' : 'alta';
    if (!cert.nif) {
      // No se guarda: en cuanto se despliegue la función "ticketbai" nueva, el siguiente envío ya lee el NIF
      certificados.delete(auth);
      return json({ error: 'Despliega antes la función "ticketbai" actualizada: no devuelve el NIF de la empresa' }, 500);
    }
    // Anular (baja) y subsanar o modificar (zuzendu-alta) son solo del administrador, igual que en la
    // base. Sin rol (función "ticketbai" antigua) tampoco se deja: falla cerrado
    if (ruta !== 'alta' && cert.rol !== 'admin') {
      return json({ error: 'Solo el administrador puede anular o subsanar facturas' }, 403);
    }
    const mal = comprobarXml(xmlFirmado, cert.nif, RAIZ[ruta]);
    if (mal) return json({ error: mal }, 400);
    const r = await enviar(host, `/sarrerak/${ruta}`, xmlFirmado, cert);
    return json(r);
  } catch (e) {
    // Nunca se vacía todo: un fallo de un usuario (p. ej. cocina, que no puede enviar) no afecta a los demás bares
    certificados.delete(auth);
    return json({ error: String(e?.message ?? e) }, 500);
  }
};

export const config = { path: '/api/tbai' };
