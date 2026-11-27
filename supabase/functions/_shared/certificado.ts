// Certificado del titular de cada bar, compartido por las funciones "ticketbai" y "alta-bar".
//
// Desde la migración 0054 el certificado se sube desde la app (Ajustes › Programa) y se guarda en
// la tabla tbai_certificados_guardados CIFRADO con AES-256-GCM. La llave está en el secreto
// TBAI_CLAVE_MAESTRA de las funciones, no en la base: con la base sola (o con la clave de servicio)
// solo se ve el cifrado. El cifrado va atado al bar: copiado a la fila de otro bar no se descifra.
// La tabla no tiene reglas de acceso: desde la app no se lee nunca, tampoco un programador.
//
// Mientras un bar no lo haya pasado al almacén, se sigue usando el secreto antiguo
// TBAI_P12_<ID> / TBAI_P12_CLAVE_<ID> (Estado del bar › «Pasar al almacén»).
import forge from 'npm:node-forge@1.4.3';
import type { SupabaseClient } from 'npm:@supabase/supabase-js@2.50.3';

export const titularDe = (cert: forge.pki.Certificate) =>
  cert.subject.attributes.map((a) => `${a.shortName ?? a.name}=${a.value}`).join(', ');

// ¿Es el certificado de este NIF? Misma regla que la app (lib/features/ticketbai/titular_nif.dart).
// Con identificador de entidad (VATES-…, el titular en los certificados de representante) tiene que
// ser ese: no vale el DNI del representante que también va en el sujeto. Sin él, el NIF tiene que
// aparecer como palabra suelta, no como trozo de otra.
export function certificadoDelNif(titular: string, nif: string): boolean {
  const t = titular.toUpperCase();
  if (!/^[A-Z0-9]{9}$/.test(nif)) return false;
  const entidad = new Set([...t.matchAll(/VATES-?([A-Z0-9]{9})/g)].map((m) => m[1]));
  if (entidad.size > 0) return entidad.has(nif);
  return new RegExp(`(^|[^A-Z0-9])${nif}([^A-Z0-9]|$)`).test(t);
}

// NIF español con su control: DNI, NIE o CIF. Igual que nif_valido (0054) y lib/core/nif.dart.
export function nifValido(nif: string): boolean {
  const n = nif.trim().toUpperCase();
  const letras = 'TRWAGMYFPDXBNJZSQVHLCKE';
  if (/^\d{8}[A-Z]$/.test(n)) return letras[Number(n.slice(0, 8)) % 23] === n[8];
  if (/^[XYZ]\d{7}[A-Z]$/.test(n)) {
    return letras[Number('XYZ'.indexOf(n[0]) + n.slice(1, 8)) % 23] === n[8];
  }
  if (/^[ABCDEFGHJNPQRSUVW]\d{7}[0-9A-J]$/.test(n)) {
    let suma = 0;
    for (let i = 1; i <= 7; i++) {
      const d = Number(n[i]);
      if (i % 2 === 0) suma += d;
      else suma += Math.floor((d * 2) / 10) + ((d * 2) % 10);
    }
    const c = (10 - (suma % 10)) % 10;
    return n[8] === String(c) || n[8] === 'JABCDEFGHI'[c];
  }
  return false;
}

// Fallo al leer o comprobar un certificado: el texto es para enseñarlo tal cual
export class CertificadoMalo extends Error {}

export type DatosCertificado = { titular: string; caduca: Date; huella: string };

const MAX_P12 = 50_000; // un .pfx normal ocupa 3-10 KB

// Abre el .p12/.pfx con su contraseña y dice qué falla, con palabras claras
export function leerDatosP12(p12Base64: string, clave: string): DatosCertificado {
  if (!p12Base64 || p12Base64.length > MAX_P12 * 1.4) throw new CertificadoMalo('El fichero no es un certificado .p12/.pfx (vacío o demasiado grande)');
  let asn1: forge.asn1.Asn1;
  try {
    asn1 = forge.asn1.fromDer(forge.util.decode64(p12Base64));
  } catch (_) {
    throw new CertificadoMalo('El fichero no es un certificado .p12/.pfx');
  }
  let p12: forge.pkcs12.Pkcs12Pfx;
  try {
    p12 = forge.pkcs12.pkcs12FromAsn1(asn1, clave);
  } catch (_) {
    throw new CertificadoMalo('La contraseña no abre el certificado');
  }
  const oidClave = forge.pki.oids.pkcs8ShroudedKeyBag;
  const bolsa = p12.getBags({ bagType: oidClave })[oidClave] ?? p12.getBags({ bagType: forge.pki.oids.keyBag })[forge.pki.oids.keyBag];
  const clavePriv = bolsa?.[0]?.key as forge.pki.rsa.PrivateKey | undefined;
  if (!clavePriv?.n) throw new CertificadoMalo('El fichero no tiene clave privada RSA: expórtalo con la clave privada');
  const certs = (p12.getBags({ bagType: forge.pki.oids.certBag })[forge.pki.oids.certBag] ?? []).map((b) => b.cert!).filter(Boolean);
  const cert = certs.find((c) => (c.publicKey as forge.pki.rsa.PublicKey).n?.equals(clavePriv.n));
  if (!cert) throw new CertificadoMalo('El fichero no trae el certificado de su clave privada');
  const der = forge.asn1.toDer(forge.pki.certificateToAsn1(cert)).getBytes();
  const md = forge.md.sha256.create();
  md.update(der);
  return { titular: titularDe(cert), caduca: cert.validity.notAfter, huella: md.digest().toHex() };
}

// Todo lo que se comprueba al subirlo para un bar: abre, es del NIF del bar y no está caducado
export function comprobarParaBar(p12Base64: string, clave: string, nif: string): DatosCertificado & { aviso?: string } {
  const d = leerDatosP12(p12Base64, clave);
  if (!certificadoDelNif(d.titular, nif)) {
    throw new CertificadoMalo(`El certificado es de «${d.titular}», no del NIF del bar (${nif})`);
  }
  const ahora = Date.now();
  if (d.caduca.getTime() <= ahora) throw new CertificadoMalo(`El certificado caducó el ${fecha(d.caduca)}`);
  const dias = Math.floor((d.caduca.getTime() - ahora) / 86_400_000);
  return dias < 30 ? { ...d, aviso: `Caduca dentro de ${dias} días (${fecha(d.caduca)}): pide ya el nuevo` } : d;
}

const fecha = (d: Date) => d.toISOString().slice(0, 10).split('-').reverse().join('/');

// ---------- Cifrado ----------
const a64 = (b: Uint8Array) => btoa(Array.from(b, (c) => String.fromCharCode(c)).join(''));
const de64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const contexto = (empresaId: string) => new TextEncoder().encode(`gestionrest-certificado-v1:${empresaId}`);

async function llaveMaestra(): Promise<CryptoKey> {
  const k = (Deno.env.get('TBAI_CLAVE_MAESTRA') ?? '').trim();
  let bytes: Uint8Array;
  try {
    bytes = de64(k);
  } catch (_) {
    bytes = new Uint8Array();
  }
  if (bytes.length !== 32) throw new Error('Falta TBAI_CLAVE_MAESTRA en los secretos del servidor (32 bytes en base64)');
  return crypto.subtle.importKey('raw', bytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
}

// base64( iv de 12 bytes || cifrado AES-256-GCM de {p12, clave} ), atado al bar
export async function cifrar(empresaId: string, p12: string, clave: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const datos = new TextEncoder().encode(JSON.stringify({ p12, clave }));
  const c = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: contexto(empresaId) }, await llaveMaestra(), datos));
  const todo = new Uint8Array(iv.length + c.length);
  todo.set(iv);
  todo.set(c, iv.length);
  return a64(todo);
}

async function descifrar(empresaId: string, cifrado: string): Promise<{ p12: string; clave: string }> {
  const todo = de64(cifrado);
  const claro = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: todo.slice(0, 12), additionalData: contexto(empresaId) }, await llaveMaestra(), todo.slice(12));
  const d = JSON.parse(new TextDecoder().decode(claro));
  return { p12: String(d.p12), clave: String(d.clave ?? '') };
}

export const nombreSecreto = (empresaId: string) => `TBAI_P12_${empresaId.replaceAll('-', '').toUpperCase()}`;

// Secreto antiguo del panel (solo mientras el bar no lo pase al almacén)
export function certificadoDelSecreto(empresaId: string): { p12: string; clave: string } | null {
  const p12 = Deno.env.get(nombreSecreto(empresaId));
  if (!p12) return null;
  return { p12, clave: Deno.env.get(`TBAI_P12_CLAVE_${empresaId.replaceAll('-', '').toUpperCase()}`) ?? '' };
}

// El certificado de un bar para firmar o enviar: primero el almacén, si no el secreto antiguo.
// [srv] es el cliente con la clave de servicio (la tabla no se lee de otra forma).
export async function certificadoDelBar(srv: SupabaseClient, empresaId: string):
  Promise<{ p12: string; clave: string; origen: 'almacen' | 'secreto' } | null> {
  const { data, error } = await srv.from('tbai_certificados_guardados').select('cifrado').eq('empresa_id', empresaId).maybeSingle();
  if (error) throw new Error(`No se pudo leer el certificado guardado: ${error.message}`);
  if (data?.cifrado) return { ...(await descifrar(empresaId, data.cifrado as string)), origen: 'almacen' };
  const s = certificadoDelSecreto(empresaId);
  return s ? { ...s, origen: 'secreto' } : null;
}
