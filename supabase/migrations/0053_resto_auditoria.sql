-- 0053 · Resto del informe de seguridad run-2 (bloque 5): pistas 13, 14, 20, 21, 23, 24 y 25, y
-- mejoras del apartado 5.
--  · Series (13): al buscar una serie libre solo cuentan las facturas de bares en producción. Un
--    bar en simulado o en pruebas ya no gasta los nombres de serie de otro titular.
--  · Certificados (14): la fila del certificado del servidor solo la escribe el servidor (función
--    "ticketbai", al probarlo). Los equipos apuntan solo la suya ("equipo …"), y la tabla
--    (con el titular) solo la lee el administrador.
--  · Fichajes sin internet (20): como mucho 48 horas atrás (antes, 7 días).
--  · Resumen diario (21) y copia mensual (24): la espera entre envíos o copias manuales la guarda
--    el servidor en una tabla que nadie toca desde la app, y se reclama de forma atómica.
--  · Fotos de productos (23): 2 MB como mucho y solo jpg, png, webp o gif.
--  · Altas de usuarios (25): la función crear-usuario apunta cada alta (usuario_creado) y pone un
--    tope por bar; aquí solo el nombre del evento.
--  · Funciones nuevas cerradas por defecto en TODOS los esquemas (lo de la 0044 solo valía para
--    "public" y no quitaba el permiso global).
--  · Probar PIN con un empleado que no es del bar cuenta como un PIN incorrecto y no dice si
--    pertenece o no al bar.
--  · El aviso diario cuenta en la base (alertas_resumen) y ya no se queda corto con muchas filas.
-- ORDEN: esta migración ANTES de desplegar las funciones resumen-diario, copia-mensual,
-- alertas-seguridad y ticketbai nuevas (usan reclamar_accion_manual y alertas_resumen).
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Series libres: solo cuentan las facturas de bares en producción
-- =====================================================================
create or replace function public.tbai_nueva_serie(p_empresa uuid, p_tipo text, p_descripcion text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nif text;
  v_entorno text;
  v_serie text;
begin
  select t.nif, t.entorno into v_nif, v_entorno from public.tbai_config t where t.empresa_id = p_empresa;
  if v_nif is null then
    raise exception 'La empresa no tiene datos fiscales';
  end if;
  -- Dos asignaciones a la vez para el mismo NIF esperan su turno
  perform pg_advisory_xact_lock(hashtext('tbai_series:' || v_nif));
  <<buscar>>
  for n in 1..99 loop
    for l in 0..25 loop
      if not exists (select 1 from public.tbai_series s where s.nif = v_nif and s.serie = chr(65 + l) || n)
         -- Facturas de otro bar con este NIF: solo si ese bar está en producción (un bar en simulado
         -- o en pruebas no gasta los nombres del titular)
         and not exists (select 1 from public.facturas f
                           join public.tbai_config c on c.empresa_id = f.empresa_id and c.entorno = 'produccion'
                          where f.nif_emisor = v_nif and f.cadena = chr(65 + l) || n) then
        v_serie := chr(65 + l) || n;
        exit buscar;
      end if;
    end loop;
  end loop;
  if v_serie is null then
    raise exception 'No quedan series libres para el NIF %', v_nif;
  end if;
  insert into public.tbai_series (empresa_id, nif, serie, tipo, descripcion, entorno)
  values (p_empresa, v_nif, v_serie, p_tipo, p_descripcion, v_entorno);
  if p_tipo = 'caja' then
    update public.cajas set serie_factura = v_serie
     where id = (select c.id from public.cajas c where c.empresa_id = p_empresa and c.activo limit 1);
  end if;
  return v_serie;
end $$;
revoke all on function public.tbai_nueva_serie(uuid, text, text) from public, anon, authenticated;

-- =====================================================================
-- 2 · Certificados: la fila del servidor la escribe el servidor; la tabla la lee el administrador
-- =====================================================================
drop policy if exists "leer_certificados" on public.tbai_certificados;
create policy "leer_certificados" on public.tbai_certificados for select to authenticated
  using ((select public.mi_rol()) = 'admin');
drop policy if exists "apuntar_certificados" on public.tbai_certificados;
create policy "apuntar_certificados" on public.tbai_certificados for insert to authenticated
  with check ((select public.mi_rol()) is not null and origen like 'equipo%');
drop policy if exists "actualizar_certificados" on public.tbai_certificados;
create policy "actualizar_certificados" on public.tbai_certificados for update to authenticated
  using ((select public.mi_rol()) is not null and origen like 'equipo%')
  with check ((select public.mi_rol()) is not null and origen like 'equipo%');

-- =====================================================================
-- 3 · Fichajes sin internet: como mucho 48 horas atrás
-- =====================================================================
create or replace function public.fichar(p_empresa uuid, p_usuario uuid, p_pin text, p_tipo text,
                                         p_momento timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text := public.fichaje_comprobar(p_empresa, p_usuario, p_pin);
  v_cuando timestamptz := coalesce(p_momento, now());
  v_ultimo text;
  v_fila public.fichajes;
begin
  if v_nombre is null then
    return jsonb_build_object('error', 'PIN incorrecto');
  end if;
  if p_tipo not in ('entrada','pausa','vuelta','salida') then
    raise exception 'Tipo de fichaje no válido';
  end if;
  if p_momento is not null and (p_momento > now() + interval '5 minutes' or p_momento < now() - interval '48 hours') then
    raise exception 'Hora del fichaje guardado sin internet fuera de plazo (más de 48 horas)';
  end if;
  -- En el momento o sin internet, tiene que seguir el orden lógico respecto al fichaje anterior
  -- a esa hora (sin internet, el anterior es el que había antes de la hora guardada)
  select f.tipo into v_ultimo from public.fichajes_vigentes f
   where f.empresa_id = p_empresa and f.usuario_id = p_usuario
     and f.momento < v_cuando and f.momento > v_cuando - interval '20 hours'
   order by f.momento desc limit 1;
  v_ultimo := coalesce(v_ultimo, 'salida');
  if (p_tipo = 'entrada' and v_ultimo <> 'salida')
     or (p_tipo = 'pausa' and v_ultimo not in ('entrada','vuelta'))
     or (p_tipo = 'vuelta' and v_ultimo <> 'pausa')
     or (p_tipo = 'salida' and v_ultimo = 'salida') then
    raise exception 'No puedes fichar % a esa hora (lo anterior fue %)', p_tipo, v_ultimo;
  end if;

  insert into public.fichajes (empresa_id, usuario_id, nombre, tipo, momento, origen)
  values (p_empresa, p_usuario, v_nombre, p_tipo, v_cuando,
          case when p_momento is null then 'tpv' else 'sin_conexion' end)
  returning * into v_fila;
  return to_jsonb(v_fila);
end $$;
grant execute on function public.fichar(uuid, uuid, text, text, timestamptz) to anon, authenticated;

-- =====================================================================
-- 4 · PIN: quien no es del bar cuenta como PIN incorrecto (no se revela si pertenece)
-- =====================================================================
create or replace function public.fichaje_comprobar(p_empresa uuid, p_usuario uuid, p_pin text)
returns text   -- nombre del empleado, o null si el PIN no es correcto (el intento queda apuntado)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text;
  v_ok boolean;
  v_fallos int;
begin
  -- Un empleado, una comprobación a la vez (0048)
  perform pg_advisory_xact_lock(hashtextextended('fichaje_comprobar:' || p_usuario::text, 0));

  -- PT429: la app lo reconoce como "espera y reintenta" (no pierde los fichajes guardados)
  if (select count(*) from public.fichaje_intentos
       where momento > now() - interval '15 minutes') >= 200 then
    raise exception 'Demasiados PIN incorrectos en este momento. Prueba en unos minutos' using errcode = 'PT429';
  end if;
  if (select count(*) from public.fichaje_intentos
       where empresa_id = p_empresa and momento > now() - interval '15 minutes') >= 20 then
    raise exception 'Demasiados PIN incorrectos en este bar. Espera 15 minutos o entra con correo' using errcode = 'PT429';
  end if;
  if (select count(*) from public.fichaje_intentos
       where usuario_id = p_usuario and momento > now() - interval '5 minutes') >= 5 then
    raise exception 'Demasiados PIN incorrectos. Espera 5 minutos' using errcode = 'PT429';
  end if;

  select p.nombre,
         extensions.crypt('GRpin-' || p_pin || '-' || split_part(p.correo, '@', 1), u.encrypted_password) = u.encrypted_password
    into v_nombre, v_ok
    from public.perfiles p
    join public.empresa_usuarios eu on eu.usuario_id = p.id and eu.empresa_id = p_empresa and eu.activo
    join auth.users u on u.id = p.id
   where p.id = p_usuario;
  -- No es del bar o el PIN no es: lo mismo para quien prueba, y cuenta como un fallo
  if v_nombre is null or not coalesce(v_ok, false) then
    insert into public.fichaje_intentos (usuario_id, empresa_id) values (p_usuario, p_empresa);
    insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
    values (p_empresa, 'pin_fallido', p_usuario, case when v_nombre is null then 'Empleado que no es de este bar' end);
    select count(*) into v_fallos from public.fichaje_intentos
     where usuario_id = p_usuario and momento > now() - interval '5 minutes';
    if v_fallos = 5 then
      insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
      values (p_empresa, 'pin_bloqueado', p_usuario, '5 PIN incorrectos seguidos: bloqueado 5 minutos');
    end if;
    if (select count(*) from public.fichaje_intentos
         where empresa_id = p_empresa and momento > now() - interval '15 minutes') = 20 then
      insert into public.eventos_seguridad (empresa_id, tipo, detalle)
      values (p_empresa, 'pin_bloqueado_bar', '20 PIN incorrectos en el bar: entrada con PIN bloqueada 15 minutos');
    end if;
    return null;   -- sin excepción: si no, se desharía lo apuntado
  end if;
  delete from public.fichaje_intentos where usuario_id = p_usuario;
  return v_nombre;
end $$;
revoke execute on function public.fichaje_comprobar(uuid, uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 5 · Esperas de los envíos y copias manuales: en el servidor, atómicas
-- =====================================================================
create table if not exists public.limites_manuales (
  empresa_id  uuid not null references public.empresa(id) on delete cascade,
  accion      text not null,
  ultimo      timestamptz not null,
  primary key (empresa_id, accion)
);
alter table public.limites_manuales enable row level security;   -- sin políticas: solo el servidor
revoke all on public.limites_manuales from anon, authenticated;

-- true si se puede hacer ahora (y queda apuntado); false si se hizo hace menos de p_minutos.
-- Una sola sentencia: dos peticiones a la vez no pasan las dos.
create or replace function public.reclamar_accion_manual(p_empresa uuid, p_accion text, p_minutos int)
returns boolean
language sql
security definer
set search_path = ''
as $$
  with r as (
    insert into public.limites_manuales as l (empresa_id, accion, ultimo)
    values (p_empresa, p_accion, now())
    on conflict (empresa_id, accion) do update set ultimo = now()
      where l.ultimo < now() - make_interval(mins => p_minutos)
    returning 1
  )
  select exists (select 1 from r)
$$;
revoke all on function public.reclamar_accion_manual(uuid, text, int) from public, anon, authenticated;
grant execute on function public.reclamar_accion_manual(uuid, text, int) to service_role;

-- =====================================================================
-- 6 · Fotos de productos: 2 MB y solo imágenes
-- =====================================================================
update storage.buckets
   set file_size_limit = 2 * 1024 * 1024,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif']
 where id = 'productos';

-- =====================================================================
-- 7 · Aviso diario: la base cuenta (sin límite de filas de la API)
-- =====================================================================
create or replace function public.alertas_resumen(p_desde timestamptz)
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'pin', coalesce((
      select jsonb_agg(x) from (
        select e.empresa_id, e.usuario_id, p.nombre,
               count(*) filter (where e.tipo = 'pin_fallido') as fallidos,
               count(*) filter (where e.tipo = 'pin_bloqueado') as bloqueos
          from public.eventos_seguridad e
          left join public.perfiles p on p.id = e.usuario_id
         where e.momento >= p_desde and e.tipo in ('pin_fallido', 'pin_bloqueado')
         group by e.empresa_id, e.usuario_id, p.nombre) x), '[]'::jsonb),
    'otros', coalesce((
      select jsonb_agg(x) from (
        select e.empresa_id, e.tipo, count(*) as n
          from public.eventos_seguridad e
         where e.momento >= p_desde and e.tipo not in ('pin_fallido', 'pin_bloqueado')
         group by e.empresa_id, e.tipo) x), '[]'::jsonb),
    'control', coalesce((
      select jsonb_agg(x) from (
        select a.empresa_id, a.tipo, count(*) as n, coalesce(sum(a.importe), 0) as importe
          from public.registro_anulaciones a
         where a.momento >= p_desde and a.tipo in ('cobro_fuera_turno', 'venta_anulada', 'linea_borrada')
         group by a.empresa_id, a.tipo) x), '[]'::jsonb))
$$;
revoke all on function public.alertas_resumen(timestamptz) from public, anon, authenticated;
grant execute on function public.alertas_resumen(timestamptz) to service_role;

-- =====================================================================
-- 8 · Funciones nuevas cerradas por defecto en todos los esquemas
-- =====================================================================
-- Sin "in schema": quita el permiso global de PUBLIC para las funciones que cree este usuario
-- (el del SQL Editor) a partir de ahora. Cada migración sigue dando sus permisos a mano.
alter default privileges revoke execute on functions from public;
alter default privileges in schema public grant execute on functions to authenticated;

-- =====================================================================
-- 9 · Cron: cada función con su secreto (resumen-diario y alertas-seguridad)
-- =====================================================================
-- Después de crear los secretos RESUMEN_SECRETO y ALERTAS_SECRETO (Edge Functions › Secrets),
-- vuelve a programar estos dos trabajos con su secreto nuevo (copia-mensual sigue con COPIA_SECRETO):
--
-- select cron.schedule('resumen-diario', '0 7 * * *', $c$
--   select net.http_post(
--     url := 'https://TU_PROYECTO.supabase.co/functions/v1/resumen-diario',
--     headers := jsonb_build_object('Content-Type', 'application/json',
--                                   'Authorization', 'Bearer TU_CLAVE_ANON',
--                                   'x-copia-secreto', 'TU_RESUMEN_SECRETO'),
--     body := '{}'::jsonb) $c$);
-- select cron.schedule('alertas-seguridad', '30 7 * * *', $c$
--   select net.http_post(
--     url := 'https://TU_PROYECTO.supabase.co/functions/v1/alertas-seguridad',
--     headers := jsonb_build_object('Content-Type', 'application/json',
--                                   'Authorization', 'Bearer TU_CLAVE_ANON',
--                                   'x-copia-secreto', 'TU_ALERTAS_SECRETO'),
--     body := '{}'::jsonb) $c$);
-- (Mira antes la hora que tenían: select jobname, schedule from cron.job;)
