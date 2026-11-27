// Edge Function "ticketbai": firma XAdES-EPES y envía a la Hacienda Foral de Gipuzkoa.
//
// Secretos necesarios (Supabase → Edge Functions → Secrets), UNO POR EMPRESA
// (<ID> = id de la empresa sin guiones, en mayúsculas; "Comprobar certificado" lo muestra):
//   TBAI_P12_<ID>        certificado .p12/.pfx en base64 del titular de esa empresa
//   TBAI_P12_CLAVE_<ID>  contraseña del certificado
// El certificado tiene que ser del NIF de la empresa: si no coincide, no se firma.
//
// Cuerpo: { accion: 'probar' }                       → datos del certificado
//         { accion: 'firmar', xml: '<T:TicketBai…>' } → XML firmado y SignatureValue
//         { accion: 'reenviar', xmlFirmado: '…' }      → envía a Hacienda un XML ya firmado
import { createClient } from 'npm:@supabase/supabase-js@2';
import forge from 'npm:node-forge@1.4.3';
import * as xadesjs from 'npm:xadesjs@3.0.0';
import * as xmlcore from 'npm:xml-core@3.0.0';
import { DOMImplementation, DOMParser, XMLSerializer } from 'npm:@xmldom/xmldom@0.9.12';

xadesjs.Application.setEngine('webcrypto', crypto);
xmlcore.setNodeDependencies({ DOMParser, XMLSerializer, DOMImplementation });

const POLITICA = {
  url: 'https://www.gipuzkoa.eus/ticketbai/sinadura',
  hash: '4LDJbY5hqHHHX858s9QV1P8yVGzo6H23P/iNRRv+PnQ=',
};
const ENDPOINT = {
  pruebas: 'https://tbai-z.prep.gipuzkoa.eus/sarrerak/alta',
  produccion: 'https://tbai-z.egoitza.gipuzkoa.eus/sarrerak/alta',
};
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const json = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

type Certificado = { key: CryptoKey; certBase64: string; certPem: string; keyPem: string; titular: string; caduca: string };

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
  // Para TLS: primero el certificado del titular, luego la cadena
  const cadena = [cert, ...certs.filter((c) => c !== cert)];
  return {
    key,
    certBase64: forge.util.encode64(certDer),
    certPem: cadena.map((c) => forge.pki.certificateToPem(c)).join('\n'),
    keyPem: forge.pki.privateKeyInfoToPem(forge.pki.wrapRsaPrivateKey(forge.pki.privateKeyToAsn1(clavePriv))),
    titular: cert.subject.attributes.map((a) => `${a.shortName ?? a.name}=${a.value}`).join(', '),
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
  // Solo el SignatureValue de la firma (ds:), no <SignatureValueFirmaFacturaAnterior> del encadenamiento
  const signatureValue = xml.match(/<(?:\w+:)?SignatureValue(?:\s[^>]*)?>([^<]+)<\/(?:\w+:)?SignatureValue>/)![1].replace(/\s/g, '');
  return { xml, signatureValue };
}

function leerRespuesta(xml: string) {
  const tag = (n: string) => xml.match(new RegExp(`<(?:\\w+:)?${n}>([\\s\\S]*?)</(?:\\w+:)?${n}>`))?.[1]?.trim() ?? null;
  const errores = [...xml.matchAll(/<(?:\w+:)?ResultadosValidacion>([\s\S]*?)<\/(?:\w+:)?ResultadosValidacion>/g)].map((m) => ({
    codigo: m[1].match(/<(?:\w+:)?Codigo>([^<]*)</)?.[1] ?? null,
    descripcion: m[1].match(/<(?:\w+:)?Descripcion>([^<]*)</)?.[1] ?? null,
  }));
  return { estado: tag('Estado'), descripcion: tag('Descripcion'), csv: tag('CSV'), fechaRecepcion: tag('FechaRecepcion'), errores };
}

async function enviar(xmlFirmado: string, cert: Certificado, entorno: 'pruebas' | 'produccion') {
  // Hacienda exige autenticarse con certificado (TLS mutuo)
  // cert/key (Deno 2) y certChain/privateKey (Deno 1.x, el que pueda tener el servidor)
  // deno-lint-ignore no-explicit-any
  const client = (Deno as any).createHttpClient({
    cert: cert.certPem,
    key: cert.keyPem,
    certChain: cert.certPem,
    privateKey: cert.keyPem,
  });
  try {
    const r = await fetch(ENDPOINT[entorno], {
      method: 'POST',
      headers: { 'Content-Type': 'application/xml;charset=UTF-8' },
      body: new TextEncoder().encode(xmlFirmado),
      client,
    });
    const texto = await r.text();
    return { http: r.status, respuesta: texto, ...leerRespuesta(texto) };
  } finally {
    client.close();
  }
}

// ¿Es el certificado de este NIF? Misma regla que la app (lib/features/ticketbai/titular_nif.dart).
// Con identificador de entidad (VATES-…, el titular en los certificados de representante) tiene que
// ser ese: no vale el DNI del representante que también va en el sujeto. Sin él, el NIF tiene que
// aparecer como palabra suelta, no como trozo de otra.
function certificadoDelNif(titular: string, nif: string): boolean {
  const t = titular.toUpperCase();
  if (nif.length !== 9) return false;
  const entidad = new Set([...t.matchAll(/VATES-?([A-Z0-9]{9})/g)].map((m) => m[1]));
  if (entidad.size > 0) return entidad.has(nif);
  return new RegExp(`(^|[^A-Z0-9])${nif.replace(/[^A-Z0-9]/g, '')}([^A-Z0-9]|$)`).test(t);
}

// Solo se firma o se envía un fichero TicketBAI de ESTE titular: raíz conocida y NIF del emisor
// igual al de la empresa. Sin comentarios, CDATA ni DOCTYPE, que servirían para esconder otro emisor.
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    // Solo usuarios con sesión y de una empresa con TicketBAI configurado
    const supa = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } },
    });
    const { data: usuario } = await supa.auth.getUser();
    if (!usuario.user) return json({ error: 'Sin sesión' }, 401);
    // tbai_config solo devuelve la de la empresa actual del usuario (RLS por empresa)
    const { data: config, error: errConfig } = await supa.from('tbai_config').select('empresa_id, entorno, nif').limit(1).single();
    if (errConfig || !config) return json({ error: 'No se pudo leer la configuración TicketBAI' }, 400);

    // Certificado de ESTA empresa (cada bar puede tener un titular distinto)
    const id = String(config.empresa_id).replaceAll('-', '').toUpperCase();
    const nombreSecreto = `TBAI_P12_${id}`;
    const p12 = Deno.env.get(nombreSecreto);
    const clave = Deno.env.get(`TBAI_P12_CLAVE_${id}`) ?? '';
    if (!p12) {
      return json({ error: `Falta el certificado de esta empresa: crea los secretos ${nombreSecreto} y TBAI_P12_CLAVE_${id}` }, 400);
    }
    const cert = await leerCertificado(p12, clave);
    const nif = String(config.nif ?? '').trim().toUpperCase();
    const coincide = certificadoDelNif(cert.titular, nif);

    const cuerpo = await req.json();
    if (cuerpo.accion === 'probar') {
      if (!coincide) {
        return json({ error: `El certificado (${cert.titular}) no es del NIF de la empresa (${nif || 'sin NIF'})` });
      }
      return json({ ok: true, titular: cert.titular, caduca: cert.caduca, entorno: config.entorno, secreto: nombreSecreto });
    }
    if (!coincide) {
      return json({ error: `El certificado configurado no es del NIF de la empresa (${nif || 'sin NIF'}): no se firma` }, 400);
    }
    // Firmar, enviar y dar el certificado al puente: solo quien cobra (nunca cocina)
    const { data: rol } = await supa.rpc('mi_rol');
    if (rol !== 'admin' && rol !== 'camarero') {
      return json({ error: 'Solo el administrador o un camarero pueden firmar y enviar facturas' }, 403);
    }
    if (cuerpo.accion === 'certificado') {
      // Solo para el servicio puente de Netlify (conoce el secreto compartido)
      const secreto = Deno.env.get('PUENTE_SECRETO');
      if (!secreto || req.headers.get('x-puente-secreto') !== secreto) return json({ error: 'No autorizado' }, 403);
      // El entorno lo decide la configuración del bar, no lo que diga la app.
      // El rol va al puente: solo un administrador puede anular o subsanar en Hacienda
      return json({ p12, clave, entorno: config.entorno, nif, rol });
    }
    if (config.entorno !== 'pruebas' && config.entorno !== 'produccion') {
      return json({ error: `El entorno es "${config.entorno}": cámbialo a pruebas o producción` }, 400);
    }
    if (cuerpo.accion === 'firmar') {
      // Primero se firma; la app guarda la factura y después la envía con 'reenviar'
      // Anular es solo del administrador, igual que en la base (tbai_anulaciones)
      if (rol !== 'admin' && String(cuerpo.xml).includes('AnulaTicketBai')) {
        return json({ error: 'Solo el administrador puede anular facturas' }, 403);
      }
      const mal = comprobarXml(cuerpo.xml, nif, rol === 'admin' ? ['TicketBai', 'AnulaTicketBai'] : ['TicketBai']);
      if (mal) return json({ error: mal }, 400);
      const { xml, signatureValue } = await firmar(cuerpo.xml as string, cert);
      return json({ ok: true, xmlFirmado: xml, signatureValue });
    }
    if (cuerpo.accion === 'reenviar') {
      // Esta acción solo envía al servicio de alta
      const mal = comprobarXml(cuerpo.xmlFirmado, nif, ['TicketBai']);
      if (mal) return json({ error: mal }, 400);
      const r = await enviar(cuerpo.xmlFirmado as string, cert, config.entorno);
      return json({ ok: true, ...r });
    }
    return json({ error: 'Acción desconocida' }, 400);
  } catch (e) {
    return json({ error: `${e}` }, 500);
  }
});
