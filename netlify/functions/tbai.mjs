// Servicio puente TicketBAI (Netlify Functions, Node).
// Envía a la Hacienda Foral de Gipuzkoa un fichero GUARDADO en la base: la app solo dice cuál
// (tabla e id). El fichero y el certificado los da la función "ticketbai" (acción preparar_envio)
// y el resultado lo apunta también ella (resultado_envio): ni el XML ni el estado vienen de la app.
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

// Llamada a la función "ticketbai" en nombre del usuario (su sesión) y con el secreto del puente
async function ticketbai(auth, cuerpo) {
  const r = await fetch(`${process.env.SUPABASE_URL}/functions/v1/ticketbai`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: process.env.SUPABASE_ANON_KEY,
      Authorization: auth,
      'x-puente-secreto': process.env.PUENTE_SECRETO ?? '',
    },
    body: JSON.stringify(cuerpo),
  });
  const d = await r.json();
  if (d.error) throw new Error(d.error);
  return d;
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
  const auth = req.headers.get('authorization') ?? '';
  try {
    // Solo usuarios con sesión en GestiónRest
    const u = await fetch(`${process.env.SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: process.env.SUPABASE_ANON_KEY, Authorization: auth },
    });
    if (!u.ok) return json({ error: 'Sin sesión' }, 401);

    const { tabla, id, xmlFirmado } = await req.json();
    if (xmlFirmado) return json({ error: 'Actualiza la app: ahora se envía lo guardado en la base' }, 400);
    if (!['facturas', 'anulaciones', 'subsanaciones'].includes(tabla) || !id) return json({ error: 'Falta qué enviar' }, 400);

    // Rol, bar, fichero guardado y certificado: lo comprueba y lo da la función "ticketbai"
    const p = await ticketbai(auth, { accion: 'preparar_envio', tabla, id });
    if (p.ocupada) return json({ ocupada: true }); // otro equipo la está enviando, o ya no está pendiente
    const host = p.entorno === 'produccion' ? 'tbai-z.egoitza.gipuzkoa.eus' : 'tbai-z.prep.gipuzkoa.eus';
    let resultado;
    try {
      const r = await enviar(host, `/sarrerak/${p.servicio}`, p.xml, { pfx: Buffer.from(p.p12, 'base64'), passphrase: p.clave ?? '' });
      resultado = { http: r.http, respuesta: r.respuesta };
    } catch (e) {
      resultado = { error: String(e?.message ?? e) };
    }
    // El estado lo escribe el servidor con lo que ha contestado Hacienda
    return json(await ticketbai(auth, { accion: 'resultado_envio', tabla, id, ...resultado }));
  } catch (e) {
    return json({ error: String(e?.message ?? e) }, 500);
  }
};

export const config = { path: '/api/tbai' };
