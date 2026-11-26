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
    const coincide = nif.length > 0 && cert.titular.toUpperCase().includes(nif);

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
    if (cuerpo.accion === 'certificado') {
      // Solo para el servicio puente de Netlify (conoce el secreto compartido)
      const secreto = Deno.env.get('PUENTE_SECRETO');
      if (!secreto || req.headers.get('x-puente-secreto') !== secreto) return json({ error: 'No autorizado' }, 403);
      // El entorno lo decide la configuración del bar, no lo que diga la app
      return json({ p12, clave, entorno: config.entorno });
    }
    if (config.entorno !== 'pruebas' && config.entorno !== 'produccion') {
      return json({ error: `El entorno es "${config.entorno}": cámbialo a pruebas o producción` }, 400);
    }
    if (cuerpo.accion === 'firmar') {
      // Primero se firma; la app guarda la factura y después la envía con 'reenviar'
      const { xml, signatureValue } = await firmar(cuerpo.xml as string, cert);
      return json({ ok: true, xmlFirmado: xml, signatureValue });
    }
    if (cuerpo.accion === 'reenviar') {
      const r = await enviar(cuerpo.xmlFirmado as string, cert, config.entorno);
      return json({ ok: true, ...r });
    }
    return json({ error: 'Acción desconocida' }, 400);
  } catch (e) {
    return json({ error: `${e}` }, 500);
  }
});
