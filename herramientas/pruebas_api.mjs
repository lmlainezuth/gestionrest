// Pruebas de API de la tanda de seguridad (bloques 1 a 4 y ventas en espera). Ver PRUEBAS.md.
// Solo para el ENTORNO DE PRUEBAS: se niega a seguir si el bar está en producción.
// No lleva claves ni PIN dentro: todo se lee de variables de entorno (o se pregunta).
//
//   node herramientas/pruebas_api.mjs                  pruebas normales
//   node herramientas/pruebas_api.mjs --bloqueos       además, bloqueo de un empleado y PIN simultáneos
//   node herramientas/pruebas_api.mjs --bloqueo-bar    además, bloqueo de todo el bar (15 minutos sin PIN)
//
// Variables (las * son obligatorias):
//   GR_URL*            dirección del proyecto Supabase de pruebas (https://xxxx.supabase.co)
//   GR_KEY*            publishable key de ese proyecto
//   GR_EMPRESA*        id del bar de pruebas
//   GR_CAMARERO_ID*    id del camarero de pruebas (cuenta de PIN)
//   GR_CAMARERO_PIN    su PIN (si no está, se pregunta)
//   GR_ADMIN_ID        id del administrador de pruebas, si entra con PIN ...
//   GR_ADMIN_PIN       ... y su PIN (si no está, se pregunta)
//   GR_ADMIN_EMAIL     ... o, si entra con correo, su correo ...
//   GR_ADMIN_PASSWORD  ... y su contraseña (si no está, se pregunta)
//   GR_PUENTE_URL      dirección del puente (https://…/api/tbai) para probar el puente
//   GR_COCINERO_ID / GR_COCINERO_PIN   un cocinero de pruebas (opcional)
//   GR_VICTIMA_ID      un empleado de pruebas que se puede bloquear (para --bloqueos)
//   GR_OTRO_ADMIN_ID   otro administrador del bar (para probar que no se cambia su PIN)
import readline from 'node:readline/promises';
import { stdin, stdout } from 'node:process';

const args = new Set(process.argv.slice(2));
const env = process.env;
const URL_SB = (env.GR_URL ?? '').replace(/\/$/, '');
const KEY = env.GR_KEY ?? '';
const EMPRESA = env.GR_EMPRESA ?? '';
for (const [n, v] of [['GR_URL', URL_SB], ['GR_KEY', KEY], ['GR_EMPRESA', EMPRESA], ['GR_CAMARERO_ID', env.GR_CAMARERO_ID]]) {
  if (!v) {
    console.error(`Falta la variable ${n}. Mira la cabecera de este fichero o PRUEBAS.md.`);
    process.exit(2);
  }
}

const rl = readline.createInterface({ input: stdin, output: stdout });
const pedir = async (texto) => (await rl.question(texto)).trim();

// ---------- Llamadas ----------
async function llamar(metodo, ruta, { token, cuerpo, cabeceras = {} } = {}) {
  const r = await fetch(`${URL_SB}${ruta}`, {
    method: metodo,
    headers: {
      apikey: KEY,
      Authorization: `Bearer ${token ?? KEY}`,
      'Content-Type': 'application/json',
      ...cabeceras,
    },
    body: cuerpo === undefined ? undefined : JSON.stringify(cuerpo),
  });
  const texto = await r.text();
  let datos = null;
  try { datos = texto ? JSON.parse(texto) : null; } catch { datos = texto; }
  return { status: r.status, datos, texto };
}
const rpc = (fn, cuerpo, token) => llamar('POST', `/rest/v1/rpc/${fn}`, { token, cuerpo });
const funcion = (fn, cuerpo, token, cabeceras) => llamar('POST', `/functions/v1/${fn}`, { token, cuerpo, cabeceras });
const tabla = (metodo, t, consulta = '', cuerpo, token, prefer = 'return=representation') =>
  llamar(metodo, `/rest/v1/${t}${consulta}`, { token, cuerpo, cabeceras: { Prefer: prefer } });

async function entrarConPin(usuario, pin) {
  const c = await rpc('correo_pin', { p_empresa: EMPRESA, p_usuario: usuario, p_pin: pin });
  if (c.status !== 200 || !c.datos) throw new Error(`correo_pin: ${c.status} ${c.texto}`);
  const correo = c.datos;
  return entrarConCorreo(correo, `GRpin-${pin}-${correo.split('@')[0]}`);
}
async function entrarConCorreo(correo, clave) {
  const r = await llamar('POST', '/auth/v1/token?grant_type=password', { cuerpo: { email: correo, password: clave } });
  if (r.status !== 200) throw new Error(`entrar: ${r.status} ${r.texto}`);
  const token = r.datos.access_token;
  await rpc('usar_empresa', { p_empresa: EMPRESA }, token);
  return token;
}

// ---------- Resultados ----------
const resultados = [];
async function prueba(nombre, fn) {
  try {
    const r = await fn();
    const ok = r === true || r?.ok === true;
    resultados.push({ nombre, ok, detalle: r?.detalle ?? '' });
    console.log(`${ok ? 'OK   ' : 'FALLO'} ${nombre}${r?.detalle ? `  (${r.detalle})` : ''}`);
  } catch (e) {
    resultados.push({ nombre, ok: false, detalle: String(e.message ?? e) });
    console.log(`FALLO ${nombre}  (${e.message ?? e})`);
  }
}
const falla = (r, texto) => ({ ok: r.status >= 400 && (!texto || r.texto.includes(texto)), detalle: `${r.status} ${r.texto.slice(0, 160)}` });
// Denegado por permisos (RLS o sin privilegio), no por un error cualquiera
const denegado = (r) => ({
  ok: r.status === 401 || r.status === 403 || /row-level security|permission denied/i.test(r.texto),
  detalle: `${r.status} ${r.texto.slice(0, 160)}`,
});

// ---------- Entrada ----------
console.log('Entrando como camarero y administrador de pruebas…');
const camPin = env.GR_CAMARERO_PIN || await pedir('PIN del camarero de pruebas: ');
const cam = await entrarConPin(env.GR_CAMARERO_ID, camPin);
let adm;
if (env.GR_ADMIN_EMAIL) {
  adm = await entrarConCorreo(env.GR_ADMIN_EMAIL, env.GR_ADMIN_PASSWORD || await pedir('Contraseña del administrador: '));
} else if (env.GR_ADMIN_ID) {
  adm = await entrarConPin(env.GR_ADMIN_ID, env.GR_ADMIN_PIN || await pedir('PIN del administrador de pruebas: '));
} else {
  console.error('Falta GR_ADMIN_ID (con PIN) o GR_ADMIN_EMAIL (con contraseña).');
  process.exit(2);
}

// Nunca contra un bar en producción
const cfg = await tabla('GET', 'tbai_config', '?select=entorno,nif&limit=1', undefined, adm);
const entorno = cfg.datos?.[0]?.entorno;
if (entorno === 'produccion' || !entorno) {
  console.error(`El bar está en "${entorno ?? 'desconocido'}": estas pruebas son solo para el entorno de pruebas o simulado.`);
  process.exit(3);
}
console.log(`Bar en entorno "${entorno}". Empiezan las pruebas.\n`);

const yoCam = (await rpc('mi_perfil', {}, cam)).datos?.[0];
const miembro = await tabla('GET', 'empresa_usuarios', `?usuario_id=eq.${env.GR_CAMARERO_ID}&select=permisos`, undefined, adm);
const permisosOriginales = miembro.datos?.[0]?.permisos ?? null;

// =====================================================================
console.log('— Bloque 1 · PIN —');
await prueba('Alta de usuario con PIN de 4 cifras: rechazada', async () =>
  falla(await funcion('crear-usuario', { nombre: 'Prueba PIN corto', rol: 'camarero', pin: '1234' }, adm), '6 y 8'));
await prueba('Cambiar el PIN propio con un PIN actual equivocado: rechazado', async () =>
  falla(await funcion('crear-usuario', { accion: 'mi_pin', actual: '000000', pin: '13572468' }, cam), 'no es correcto'));
await prueba('limpiar_seguridad no la puede llamar la app', async () => denegado(await rpc('limpiar_seguridad', {}, adm)));

// =====================================================================
console.log('\n— Bloque 2 · Cuentas y ventas —');
const producto = (await tabla('GET', 'productos', '?activo=eq.true&select=id,precio_venta,area_id,nombre&limit=1', undefined, cam)).datos?.[0];
const nuevoPedido = async (nombre) =>
  (await tabla('POST', 'pedidos', '', { tipo: 'barra', nombre_llevar: nombre, camarero_id: yoCam?.id }, cam)).datos?.[0];
const pedidoA = await nuevoPedido('PRUEBA API A');
const pedidoB = await nuevoPedido('PRUEBA API B');
if (!producto || !pedidoA || !pedidoB) {
  console.log('FALLO No se pudo preparar un producto y dos cuentas de prueba (¿el camarero tiene el permiso de barra?)');
} else {
  const linea = async (pedido, precio) =>
    (await tabla('POST', 'pedido_detalle', '', {
      pedido_id: pedido.id, producto_id: producto.id, area_id: producto.area_id, descripcion: producto.nombre,
      cantidad: 1, precio_unitario: precio, estado_cocina: 'servido',
    }, cam)).datos?.[0];
  await prueba('Línea con precio 0,01: queda con el precio del producto', async () => {
    const l = await linea(pedidoA, 0.01);
    return { ok: Number(l?.precio_unitario) === Number(producto.precio_venta), detalle: `${l?.precio_unitario} vs ${producto.precio_venta}` };
  });
  await prueba('Línea con precio negativo: queda con el precio del producto', async () => {
    const l = await linea(pedidoA, -5);
    return { ok: Number(l?.precio_unitario) === Number(producto.precio_venta), detalle: `${l?.precio_unitario}` };
  });
  const lB = await linea(pedidoB, producto.precio_venta);
  await prueba('Cambiar el total de una cuenta a mano: rechazado', async () =>
    falla(await tabla('PATCH', 'pedidos', `?id=eq.${pedidoA.id}`, { total: 0 }, cam), 'calculan sus platos'));
  await prueba('Pasar a pagado sin cobros: rechazado', async () =>
    falla(await tabla('PATCH', 'pedidos', `?id=eq.${pedidoA.id}`, { estado: 'pagado' }, cam), 'Faltan cobros'));
  await prueba('Escribir reparto_de en una línea: rechazado', async () =>
    falla(await tabla('PATCH', 'pedido_detalle', `?id=eq.${lB?.id}`, { reparto_de: lB?.id }, cam), 'Dividir'));
  await prueba('cancelar_reparto con la misma cuenta dos veces: rechazado', async () =>
    falla(await rpc('cancelar_reparto', { p_nuevo: pedidoA.id, p_original: pedidoA.id }, cam), 'Elige la cuenta'));
  await prueba('cancelar_reparto entre dos cuentas sin reparto: rechazado', async () =>
    falla(await rpc('cancelar_reparto', { p_nuevo: pedidoB.id, p_original: pedidoA.id }, cam), 'no es un reparto'));
  await prueba('Extras sueltos (pedido_detalle_modificadores) desde el camarero: rechazado', async () =>
    denegado(await tabla('POST', 'pedido_detalle_modificadores', '', { detalle_id: lB?.id, modificador_id: lB?.id, precio: -20 }, cam)));
  await prueba('Cuenta nueva con un total escrito: el total vuelve a 0', async () => {
    const p = (await tabla('POST', 'pedidos', '', { tipo: 'barra', nombre_llevar: 'PRUEBA API C', total: 999 }, cam)).datos?.[0];
    if (p) await tabla('PATCH', 'pedidos', `?id=eq.${p.id}`, { estado: 'anulado' }, cam);
    return { ok: Number(p?.total) === 0, detalle: `total ${p?.total}` };
  });
  // Recoger: las cuentas de prueba se anulan (queda en el registro de control, es lo esperado)
  for (const p of [pedidoA, pedidoB]) await tabla('PATCH', 'pedidos', `?id=eq.${p.id}`, { estado: 'anulado' }, cam);
}

// =====================================================================
console.log('\n— Bloque 3 · TicketBAI —');
await prueba('firmar un alta siendo camarero: 403', async () =>
  falla(await funcion('ticketbai', { accion: 'firmar', xml: '<T:TicketBai xmlns:T="urn:ticketbai:emision"/>' }, cam)));
await prueba('registrar una factura que no cuadra: 400', async () =>
  falla(await funcion('ticketbai', { accion: 'registrar', fila: { serie: 'X', numero: 1, xml: '<T:TicketBai/>' }, firmada: false }, cam)));
await prueba('Insertar una factura directamente: rechazado', async () =>
  denegado(await tabla('POST', 'facturas', '', { serie: 'X', numero: 1 }, cam)));
await prueba('Insertar una factura directamente siendo administrador (sin legado): rechazado', async () =>
  denegado(await tabla('POST', 'facturas', '', { serie: 'X', numero: 1, legado: false }, adm)));
const pendiente = (await tabla('GET', 'facturas', '?estado_envio=eq.pendiente&select=id&limit=1', undefined, cam)).datos?.[0];
await prueba('Cambiar el estado de envío de una factura: no cambia', async () => {
  if (!pendiente) return { ok: true, detalle: 'no hay facturas pendientes para probarlo (haz la prueba de la app con el puente apagado)' };
  const r = await tabla('PATCH', 'facturas', `?id=eq.${pendiente.id}`, { estado_envio: 'enviada' }, cam);
  const despues = (await tabla('GET', 'facturas', `?id=eq.${pendiente.id}&select=estado_envio`, undefined, adm)).datos?.[0];
  return { ok: despues?.estado_envio === 'pendiente', detalle: `${r.status}, sigue ${despues?.estado_envio}` };
});
await prueba('preparar_envio sin el secreto del puente: 403', async () =>
  falla(await funcion('ticketbai', { accion: 'preparar_envio', tabla: 'facturas', id: '00000000-0000-0000-0000-000000000000' }, cam)));
await prueba('tbai_ultima_factura devuelve solo id, serie, número, fecha y firma', async () => {
  const caja = (await tabla('GET', 'cajas', '?select=serie_factura&limit=1', undefined, cam)).datos?.[0];
  const r = await rpc('tbai_ultima_factura', { p_cadena: caja?.serie_factura ?? 'T1' }, cam);
  const claves = Object.keys(r.datos?.[0] ?? {}).sort().join(',');
  return { ok: r.status === 200 && (claves === '' || claves === 'fecha,firma,id,numero,serie'), detalle: claves || 'cadena sin facturas' };
});
if (env.GR_PUENTE_URL) {
  await prueba('El puente no acepta XML de la app', async () => {
    const r = await fetch(env.GR_PUENTE_URL, {
      method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${cam}` },
      body: JSON.stringify({ xmlFirmado: '<x/>' }),
    });
    const t = await r.text();
    return { ok: t.includes('Actualiza la app'), detalle: `${r.status} ${t.slice(0, 120)}` };
  });
}
if (env.GR_COCINERO_ID) {
  const coc = await entrarConPin(env.GR_COCINERO_ID, env.GR_COCINERO_PIN || await pedir('PIN del cocinero de pruebas: '));
  await prueba('Cocinero: probar el certificado, 403', async () => falla(await funcion('ticketbai', { accion: 'probar' }, coc)));
  await prueba('Cocinero: tbai_ultima_factura no devuelve nada', async () => {
    const r = await rpc('tbai_ultima_factura', { p_cadena: 'T1' }, coc);
    return { ok: Array.isArray(r.datos) && r.datos.length === 0, detalle: `${r.status} ${r.texto.slice(0, 80)}` };
  });
  await prueba('Cocinero: no ve subsanaciones ni anulaciones', async () => {
    const a = await tabla('GET', 'tbai_subsanaciones', '?select=id&limit=1', undefined, coc);
    const b = await tabla('GET', 'tbai_anulaciones', '?select=id&limit=1', undefined, coc);
    return { ok: (a.datos ?? []).length === 0 && (b.datos ?? []).length === 0, detalle: `${a.texto.slice(0, 40)} / ${b.texto.slice(0, 40)}` };
  });
}

// =====================================================================
console.log('\n— Bloque 4 · Permisos —');
await prueba('Camarero sin el permiso de cierres: no lee la tabla de turnos', async () => {
  const r = await tabla('GET', 'turnos_caja', '?select=id&limit=5', undefined, cam);
  return { ok: Array.isArray(r.datos) && r.datos.length === 0, detalle: `${r.datos?.length ?? r.texto} filas` };
});
await prueba('Camarero: turno_abierto responde (sin fondo si no abrió él la caja)', async () => {
  const caja = (await tabla('GET', 'cajas', '?select=id&activo=eq.true&limit=1', undefined, cam)).datos?.[0];
  const r = await rpc('turno_abierto', { p_caja: caja?.id }, cam);
  return { ok: r.status === 200, detalle: r.datos ? `fondo ${r.datos.efectivo_inicial ?? 'oculto'}` : 'caja cerrada' };
});
// Permisos recortados a {mesas} y vuelta a dejarlos como estaban
const recorte = await tabla('PATCH', 'empresa_usuarios', `?usuario_id=eq.${env.GR_CAMARERO_ID}&empresa_id=eq.${EMPRESA}`, { permisos: ['mesas'] }, adm);
if (recorte.status >= 300) {
  console.log(`FALLO No se pudieron recortar los permisos del camarero (${recorte.texto.slice(0, 120)})`);
} else {
  await prueba('Con solo «mesas»: tengo_permiso(cobrar) es falso', async () => {
    const r = await rpc('tengo_permiso', { p: 'cobrar' }, cam);
    return { ok: r.datos === false, detalle: `${r.texto}` };
  });
  await prueba('Con solo «mesas»: abrir un turno de caja, rechazado', async () => {
    const caja = (await tabla('GET', 'cajas', '?select=id&activo=eq.true&limit=1', undefined, cam)).datos?.[0];
    return denegado(await tabla('POST', 'turnos_caja', '', { caja_id: caja?.id, usuario_id: yoCam?.id, efectivo_inicial: 0 }, cam));
  });
  await prueba('Con solo «mesas»: el fondo sugerido no llega', async () => {
    const caja = (await tabla('GET', 'cajas', '?select=id&activo=eq.true&limit=1', undefined, cam)).datos?.[0];
    const r = await rpc('fondo_sugerido', { p_caja: caja?.id }, cam);
    return { ok: r.datos == null, detalle: r.texto.slice(0, 80) };
  });
  await prueba('Con solo «mesas»: abrir una cuenta de barra, rechazado', async () =>
    falla(await tabla('POST', 'pedidos', '', { tipo: 'barra', nombre_llevar: 'PRUEBA SIN PERMISO' }, cam), 'barra'));
  await prueba('Con solo «mesas»: escribir en stock, rechazado', async () =>
    denegado(await tabla('POST', 'articulos_stock', '', { nombre: 'PRUEBA', unidad: 'ud' }, cam)));
  await tabla('PATCH', 'empresa_usuarios', `?usuario_id=eq.${env.GR_CAMARERO_ID}&empresa_id=eq.${EMPRESA}`, { permisos: permisosOriginales }, adm);
  console.log('      (permisos del camarero devueltos a como estaban)');
}
const admins = (await tabla('GET', 'empresa_usuarios', `?empresa_id=eq.${EMPRESA}&rol=eq.admin&activo=eq.true&select=usuario_id`, undefined, adm)).datos ?? [];
const yoAdm = (await rpc('mi_perfil', {}, adm)).datos?.[0];
if (admins.length === 1 && admins[0].usuario_id === yoAdm?.id) {
  await prueba('El único administrador no se puede quitar el rol', async () =>
    falla(await tabla('PATCH', 'empresa_usuarios', `?usuario_id=eq.${yoAdm.id}&empresa_id=eq.${EMPRESA}`, { rol: 'camarero' }, adm), 'sin ningún administrador'));
} else {
  console.log('      (sin probar «último administrador»: el bar tiene más de un administrador activo; pruébalo desde la app)');
}
if (env.GR_OTRO_ADMIN_ID) {
  await prueba('Cambiar el PIN de otro administrador: 403', async () =>
    falla(await funcion('crear-usuario', { accion: 'pin', id: env.GR_OTRO_ADMIN_ID, pin: '24681357' }, adm), 'solo lo puede cambiar'));
}

// =====================================================================
console.log('\n— Ventas en espera —');
await prueba('Insertar en ventas_espera desde la app (administrador): rechazado', async () =>
  denegado(await tabla('POST', 'ventas_espera', '', { id: crypto.randomUUID(), empresa_id: EMPRESA, serie: 'X', numero: 1, venta: {}, xml: '<x/>' }, adm)));
await prueba('Cambiar una venta en espera (administrador): rechazado', async () =>
  denegado(await tabla('PATCH', 'ventas_espera', '?id=eq.00000000-0000-0000-0000-000000000000', { motivo_rechazo: 'x' }, adm)));
await prueba('Borrar una venta en espera (administrador): rechazado', async () =>
  denegado(await tabla('DELETE', 'ventas_espera', '?id=eq.00000000-0000-0000-0000-000000000000', undefined, adm)));
await prueba('apartar con un fichero de otro NIF: rechazado', async () => {
  const xml = '<?xml version="1.0" encoding="UTF-8"?><T:TicketBai xmlns:T="urn:ticketbai:emision"><Sujetos><Emisor><NIF>B99999999</NIF></Emisor></Sujetos></T:TicketBai>';
  return falla(await funcion('ticketbai', { accion: 'apartar', motivo: 'prueba', venta: { factura: { id: crypto.randomUUID(), xml } } }, cam), 'NIF');
});
await prueba('apartar con un fichero de más de 200 KB: rechazado', async () => {
  const xml = `<?xml version="1.0"?><T:TicketBai xmlns:T="urn:ticketbai:emision">${'x'.repeat(210_000)}</T:TicketBai>`;
  return falla(await funcion('ticketbai', { accion: 'apartar', motivo: 'prueba', venta: { factura: { id: crypto.randomUUID(), xml } } }, cam));
});
await prueba('forzar siendo camarero: 403', async () =>
  falla(await funcion('ticketbai', { accion: 'forzar', id: crypto.randomUUID(), motivo: 'motivo de prueba largo' }, cam)));
await prueba('forzar sin motivo (administrador): 400', async () =>
  falla(await funcion('ticketbai', { accion: 'forzar', id: crypto.randomUUID(), motivo: 'corto' }, adm), 'motivo'));

// =====================================================================
if (args.has('--bloqueos')) {
  console.log('\n— Bloqueos de PIN (empleado de pruebas GR_VICTIMA_ID) —');
  const victima = env.GR_VICTIMA_ID;
  if (!victima) {
    console.log('FALLO Falta GR_VICTIMA_ID: un empleado de pruebas que se pueda bloquear 5 minutos');
  } else {
    await prueba('20 PIN falsos a la vez: solo cuentan 5 y el resto se bloquea', async () => {
      const rs = await Promise.all(Array.from({ length: 20 }, (_, i) =>
        rpc('correo_pin', { p_empresa: EMPRESA, p_usuario: victima, p_pin: String(900000 + i) })));
      const nulos = rs.filter((r) => r.status === 200 && r.datos == null).length;
      const bloqueos = rs.filter((r) => r.texto.includes('Demasiados')).length;
      return { ok: nulos <= 5 && nulos + bloqueos === 20, detalle: `${nulos} probados, ${bloqueos} bloqueados` };
    });
    await prueba('Bloqueado: también con un PIN cualquiera dice "Demasiados PIN incorrectos"', async () =>
      falla(await rpc('correo_pin', { p_empresa: EMPRESA, p_usuario: victima, p_pin: '123456' }), 'Demasiados'));
    console.log('      (espera 5 minutos para volver a usar a ese empleado)');
  }
}
if (args.has('--bloqueo-bar')) {
  console.log('\n— Bloqueo de todo el bar (20 PIN falsos repartidos): nadie entra con PIN durante 15 minutos —');
  const equipo = ((await rpc('equipo_login', { p_empresa: EMPRESA })).datos ?? []).map((e) => e.id);
  const otros = equipo.filter((id) => id !== env.GR_CAMARERO_ID && id !== env.GR_ADMIN_ID);
  if (otros.length < 4) {
    console.log('FALLO Hacen falta al menos 4 empleados de pruebas además del camarero y el administrador');
  } else {
    for (let i = 0; i < 20; i++) await rpc('correo_pin', { p_empresa: EMPRESA, p_usuario: otros[i % 4], p_pin: String(800000 + i) });
    await prueba('Bar bloqueado: el camarero tampoco entra con su PIN bueno', async () =>
      falla(await rpc('correo_pin', { p_empresa: EMPRESA, p_usuario: env.GR_CAMARERO_ID, p_pin: camPin }), 'en este bar'));
  }
}

rl.close();
const mal = resultados.filter((r) => !r.ok);
console.log(`\n${resultados.length - mal.length} de ${resultados.length} pruebas bien.`);
if (mal.length) {
  console.log('Fallan:');
  for (const r of mal) console.log(` · ${r.nombre}: ${r.detalle}`);
}
process.exit(mal.length ? 1 : 0);
