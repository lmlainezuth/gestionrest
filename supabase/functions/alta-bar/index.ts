// GestiónRest · alta de bares, certificado del titular y paso a producción (migración 0054).
// SOLO programadores (tabla programadores) que entran con correo: nunca una cuenta de PIN, que un
// administrador de bar podría cambiar (pista 12 del informe de seguridad).
//
// No firma ni envía nada y no recibe ficheros TicketBAI (pista 1). El certificado se comprueba, se
// cifra y se guarda; ninguna respuesta lo devuelve, ni su contraseña. El titular y la caducidad solo
// los ve el programador (pista 17).
//
// Cuerpo: { accion: 'bares' }                                       → bares con su entorno
//         { accion: 'comprobar_certificado', nif, p12, clave }      → comprueba sin guardar nada
//         { accion: 'crear', nombre, razon, nif, p12, clave, admin_nombre, pin }
//         { accion: 'certificado', empresa_id, p12, clave }         → sustituye el certificado
//         { accion: 'importar_secreto', empresa_id }                → pasa TBAI_P12_<ID> al almacén
//         { accion: 'estado', empresa_id }                          → todo en verde o rojo
//         { accion: 'produccion', empresa_id, confirmacion }        → pasa el bar a producción
//
// Secretos: SUPABASE_SERVICE_ROLE_KEY, TBAI_CLAVE_MAESTRA (y los TBAI_P12_<ID> antiguos mientras existan).
// Desplegar con: supabase functions deploy alta-bar
import { createClient } from 'npm:@supabase/supabase-js@2.50.3';
import {
  CertificadoMalo, certificadoDelNif, certificadoDelBar, certificadoDelSecreto, cifrar, comprobarParaBar,
  leerDatosP12, nifValido, nombreSecreto,
} from '../_shared/certificado.ts';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const MAX_ALTAS_HORA = 5;
// Misma regla que la app (lib/features/auth/pin.dart) y crear-usuario
const claveDePin = (pin: string, correo: string) => `GRpin-${pin}-${correo.split('@')[0]}`;
const esUuid = (s: unknown) => typeof s === 'string' && /^[0-9a-f-]{36}$/i.test(s);
const fecha = (d: Date | string) => new Date(d).toISOString().slice(0, 10);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const srv = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const evento = async (empresa: string | null, tipo: string, usuario: string, detalle: string) => {
    try {
      await srv.from('eventos_seguridad').insert({ empresa_id: empresa, tipo, usuario_id: usuario, detalle: detalle.slice(0, 500) });
    } catch (_) { /* no es crítico */ }
  };

  try {
    // ---------- Quién llama: programador con cuenta de correo ----------
    const jwt = (req.headers.get('Authorization') ?? '').replace('Bearer ', '');
    const { data: { user } } = await srv.auth.getUser(jwt);
    if (!user) return json({ error: 'No has iniciado sesión' }, 401);
    const { data: prog } = await srv.from('programadores').select('usuario_id').eq('usuario_id', user.id).maybeSingle();
    if (!prog) return json({ error: 'Solo el programador puede hacer esto' }, 403);
    if ((user.email ?? '').toLowerCase().endsWith('@gestionrest.local')) {
      return json({ error: 'El programador tiene que entrar con su correo, no con PIN' }, 403);
    }

    const b = await req.json().catch(() => ({}));
    const p12 = typeof b.p12 === 'string' ? b.p12.replace(/\s/g, '') : '';
    const clave = typeof b.clave === 'string' ? b.clave : '';

    // Datos del bar (para las acciones sobre uno existente)
    const bar = async () => {
      if (!esUuid(b.empresa_id)) throw new CertificadoMalo('Falta el bar');
      const { data } = await srv.from('empresa').select('id, nombre, tbai_config(nif, razon_social, entorno)')
        .eq('id', b.empresa_id).maybeSingle();
      // deno-lint-ignore no-explicit-any
      const cfg = (Array.isArray(data?.tbai_config) ? data.tbai_config[0] : data?.tbai_config) as any;
      if (!data || !cfg) throw new CertificadoMalo('Ese bar no existe o no tiene datos fiscales');
      return { id: data.id as string, nombre: data.nombre as string, nif: String(cfg.nif).toUpperCase(), razon: cfg.razon_social as string, entorno: cfg.entorno as string };
    };

    if (b.accion === 'bares') {
      const { data, error } = await srv.from('empresa').select('id, nombre, tbai_config(nif, entorno)').order('nombre');
      if (error) return json({ error: error.message }, 400);
      return json({
        // deno-lint-ignore no-explicit-any
        bares: (data ?? []).map((e: any) => {
          const c = Array.isArray(e.tbai_config) ? e.tbai_config[0] : e.tbai_config;
          return { id: e.id, nombre: e.nombre, nif: c?.nif ?? null, entorno: c?.entorno ?? null };
        }),
      });
    }

    if (b.accion === 'comprobar_certificado') {
      const nif = String(b.nif ?? '').trim().toUpperCase();
      if (!nifValido(nif)) return json({ error: `El NIF ${nif || '(vacío)'} no es válido` }, 400);
      const d = comprobarParaBar(p12, clave, nif);
      return json({ ok: true, titular: d.titular, caduca: fecha(d.caduca), aviso: d.aviso ?? null });
    }

    if (b.accion === 'crear') {
      const nombre = String(b.nombre ?? '').trim();
      const razon = String(b.razon ?? '').trim();
      const nif = String(b.nif ?? '').trim().toUpperCase();
      const adminNombre = String(b.admin_nombre ?? '').trim();
      const pin = String(b.pin ?? '');
      if (!nombre || nombre.length > 100) return json({ error: 'Escribe el nombre del bar' }, 400);
      if (!razon || razon.length > 120) return json({ error: 'Escribe el titular' }, 400);
      if (nif === 'B00000000' || !nifValido(nif)) return json({ error: `El NIF ${nif || '(vacío)'} no es válido` }, 400);
      if (!adminNombre || adminNombre.length > 80) return json({ error: 'Escribe el nombre del administrador' }, 400);
      if (!/^\d{6,8}$/.test(pin)) return json({ error: 'El PIN debe tener entre 6 y 8 cifras' }, 400);
      const d = comprobarParaBar(p12, clave, nif);

      // Tope: el registro de cuentas y de series es compartido por todos los bares
      const { count } = await srv.from('eventos_seguridad').select('id', { count: 'exact', head: true })
        .eq('tipo', 'alta_bar').eq('usuario_id', user.id).gte('momento', new Date(Date.now() - 3600_000).toISOString());
      if ((count ?? 0) >= MAX_ALTAS_HORA) return json({ error: `Más de ${MAX_ALTAS_HORA} altas de bar en una hora: espera un rato` }, 429);

      // El cifrado va atado al bar, que aún no existe: se cifra con el id que se le dará al crearlo.
      // Antes que la cuenta: si falta la llave maestra, no se crea nada.
      const empresaId = crypto.randomUUID();
      const cifrado = await cifrar(empresaId, p12, clave);

      // Cuenta del administrador; si el alta falla se borra: nunca queda nada a medias
      const correo = `u${crypto.randomUUID().replaceAll('-', '').slice(0, 12)}@gestionrest.local`;
      const { data: nuevo, error: errUsuario } = await srv.auth.admin.createUser({
        email: correo, password: claveDePin(pin, correo), email_confirm: true, user_metadata: { nombre: adminNombre },
      });
      if (errUsuario || !nuevo.user) return json({ error: `No se pudo crear el administrador: ${errUsuario?.message}` }, 400);
      const { data: alta, error } = await srv.rpc('alta_bar_crear', {
        p_id: empresaId, p_nombre: nombre, p_razon: razon, p_nif: nif, p_admin: nuevo.user.id, p_admin_nombre: adminNombre,
        p_programador: user.id, p_cifrado: cifrado, p_titular: d.titular, p_caduca: d.caduca.toISOString(), p_huella: d.huella,
      });
      if (error) {
        await srv.auth.admin.deleteUser(nuevo.user.id);
        return json({ error: error.message }, 400);
      }
      return json({ ok: true, ...(alta as Record<string, unknown>), titular: d.titular, caduca: fecha(d.caduca), aviso: d.aviso ?? null });
    }

    if (b.accion === 'certificado' || b.accion === 'importar_secreto') {
      const e = await bar();
      let datos = { p12, clave };
      let motivo = 'Certificado sustituido desde la app';
      if (b.accion === 'importar_secreto') {
        const s = certificadoDelSecreto(e.id);
        if (!s) return json({ error: `No hay secreto ${nombreSecreto(e.id)} para este bar` }, 400);
        datos = s;
        motivo = 'Certificado pasado desde los secretos del panel';
      }
      const d = comprobarParaBar(datos.p12, datos.clave, e.nif);
      const { error } = await srv.rpc('guardar_certificado_bar', {
        p_empresa: e.id, p_nif: e.nif, p_cifrado: await cifrar(e.id, datos.p12, datos.clave), p_titular: d.titular,
        p_caduca: d.caduca.toISOString(), p_huella: d.huella, p_usuario: user.id, p_motivo: motivo,
      });
      if (error) return json({ error: error.message }, 400);
      return json({
        ok: true, titular: d.titular, caduca: fecha(d.caduca), aviso: d.aviso ?? null,
        recuerda: b.accion === 'importar_secreto'
          ? `Ya está en el almacén: borra los secretos ${nombreSecreto(e.id)} y TBAI_P12_CLAVE_… del panel` : null,
      });
    }

    if (b.accion === 'estado') {
      const e = await bar();
      const [{ data: comprobaciones, error: errC }, { data: guardado }, { data: ultimas }, pendientes, rechazadas, { data: espera }] = await Promise.all([
        srv.rpc('alta_bar_comprobaciones', { p_empresa: e.id }),
        srv.from('tbai_certificados_guardados').select('titular, caduca, subido_en').eq('empresa_id', e.id).maybeSingle(),
        srv.from('facturas').select('serie, numero, fecha, estado_envio').eq('empresa_id', e.id).eq('estado_envio', 'enviada')
          .order('fecha', { ascending: false }).limit(5),
        srv.from('facturas').select('id', { count: 'exact', head: true }).eq('empresa_id', e.id).eq('estado_envio', 'pendiente'),
        srv.from('facturas').select('id', { count: 'exact', head: true }).eq('empresa_id', e.id).eq('estado_envio', 'error'),
        srv.from('ventas_espera').select('id').eq('empresa_id', e.id).limit(1000),
      ]);
      if (errC) return json({ error: errC.message }, 400);
      let sinResolver = 0;
      if (espera && espera.length) {
        const { data: hechas } = await srv.from('facturas').select('id').in('id', espera.map((v) => v.id));
        sinResolver = espera.length - (hechas?.length ?? 0);
      }
      // Certificado: el del almacén, o el secreto antiguo (se lee solo para enseñar titular y caducidad)
      let certificado: Record<string, unknown> = { origen: null };
      if (guardado) {
        certificado = { origen: 'almacen', titular: guardado.titular, caduca: fecha(guardado.caduca as string), subido: fecha(guardado.subido_en as string) };
      } else {
        const s = certificadoDelSecreto(e.id);
        if (s) {
          try {
            const d = leerDatosP12(s.p12, s.clave);
            certificado = { origen: 'secreto', titular: d.titular, caduca: fecha(d.caduca), del_nif: certificadoDelNif(d.titular, e.nif) };
          } catch (x) {
            certificado = { origen: 'secreto', error: x instanceof CertificadoMalo ? x.message : String(x) };
          }
        }
      }
      return json({
        bar: e, certificado, comprobaciones,
        facturas: { ultimas: ultimas ?? [], pendientes: pendientes.count ?? 0, rechazadas: rechazadas.count ?? 0 },
        en_espera: sinResolver,
      });
    }

    if (b.accion === 'produccion') {
      const e = await bar();
      // El certificado de verdad (no solo lo apuntado): se descifra, se abre y se mira el NIF
      try {
        const g = await certificadoDelBar(srv, e.id);
        if (!g || g.origen !== 'almacen') throw new CertificadoMalo('El certificado tiene que estar en el almacén');
        comprobarParaBar(g.p12, g.clave, e.nif);
      } catch (x) {
        const motivo = x instanceof CertificadoMalo ? x.message : String(x);
        await evento(e.id, 'produccion_denegada', user.id, `No pasó a producción: ${motivo}`);
        return json({ error: motivo }, 400);
      }
      const { data, error } = await srv.rpc('pasar_produccion', { p_empresa: e.id, p_usuario: user.id, p_confirmacion: String(b.confirmacion ?? '') });
      if (error) {
        await evento(e.id, 'produccion_denegada', user.id, `No pasó a producción: ${error.message}`);
        return json({ error: error.message }, 400);
      }
      return json({ ok: true, ...(data as Record<string, unknown>) });
    }

    return json({ error: 'Acción desconocida' }, 400);
  } catch (e) {
    if (e instanceof CertificadoMalo) return json({ error: e.message }, 400);
    return json({ error: `${e}` }, 500);
  }
});
