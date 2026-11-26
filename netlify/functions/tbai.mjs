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

async function leerCertificado(auth) {
  if (certificados.has(auth)) return certificados.get(auth);
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
  const certificado = { pfx: Buffer.from(d.p12, 'base64'), passphrase: d.clave ?? '', entorno: d.entorno };
  if (certificados.size > 100) certificados.clear();
  certificados.set(auth, certificado);
  return certificado;
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
  try {
    // Solo usuarios con sesión en GestiónRest
    const auth = req.headers.get('authorization') ?? '';
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
    const r = await enviar(host, `/sarrerak/${ruta}`, xmlFirmado, cert);
    return json(r);
  } catch (e) {
    certificados.clear();
    return json({ error: String(e?.message ?? e) }, 500);
  }
};

export const config = { path: '/api/tbai' };
