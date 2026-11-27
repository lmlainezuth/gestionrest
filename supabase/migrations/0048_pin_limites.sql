-- 0048 · Entrada con PIN más difícil de adivinar (informe de seguridad run-2, pistas 4, 6, 18 y 22).
--  · Los intentos simultáneos ya no se saltan el límite: cada comprobación de PIN de un empleado
--    espera a la anterior (candado por empleado).
--  · Límite de fallos también por bar (20 en 15 minutos) y para toda la plataforma (200 en
--    15 minutos), además del de cada empleado (5 en 5 minutos). OJO: quien conozca el id del bar
--    puede provocar el bloqueo del bar entero durante 15 minutos; queda apuntado en Seguridad y
--    se puede entrar con correo y contraseña.
--  · PIN de 6 cifras como mínimo para todos. Las cuentas de PIN con un PIN más corto
--    (perfiles.pin_seguro = false) no tienen rol en la base hasta que lo cambian: la app nueva
--    les pide cambiarlo nada más entrar. Fichar con el PIN corto sigue funcionando.
--  · Limpieza diaria: eventos de seguridad de más de 180 días e intentos de más de 1 día.
-- ORDEN: 1) la función crear-usuario nueva, 2) la app nueva en todos los equipos, 3) esta
-- migración. Si se ejecuta antes que la app, los empleados con PIN corto no podrán trabajar hasta
-- tener la app nueva. Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Intentos con bar, para poder contarlos por bar
-- =====================================================================
alter table public.fichaje_intentos add column if not exists empresa_id uuid;
create index if not exists fichaje_intentos_empresa_idx on public.fichaje_intentos (empresa_id, momento);
create index if not exists fichaje_intentos_momento_idx on public.fichaje_intentos (momento);

-- =====================================================================
-- 2 · Comprobación de PIN con candado y límites por empleado, bar y plataforma
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
  -- Un empleado, una comprobación a la vez: si no, varias peticiones simultáneas veían todas
  -- menos de 5 fallos y cada una probaba un PIN
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
  if v_nombre is null then
    raise exception 'Este empleado no pertenece a este bar';
  end if;
  if not coalesce(v_ok, false) then
    insert into public.fichaje_intentos (usuario_id, empresa_id) values (p_usuario, p_empresa);
    insert into public.eventos_seguridad (empresa_id, tipo, usuario_id) values (p_empresa, 'pin_fallido', p_usuario);
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
-- 3 · Sin PIN de 6 cifras, una cuenta de PIN no tiene rol ni bar en la base
-- =====================================================================
-- Las cuentas con correo y contraseña no cambian. Fichar no usa esto (va con el PIN, sin sesión).
create or replace function public.empresa_actual()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select p.empresa_actual
  from public.perfiles p
  join public.empresa_usuarios eu
    on eu.empresa_id = p.empresa_actual and eu.usuario_id = p.id and eu.activo
  where p.id = auth.uid()
    and (p.pin_seguro or p.correo not like '%@gestionrest.local')
$$;

create or replace function public.mi_rol()
returns text
language sql stable security definer
set search_path = ''
as $$
  select eu.rol
  from public.perfiles p
  join public.empresa_usuarios eu
    on eu.empresa_id = p.empresa_actual and eu.usuario_id = p.id and eu.activo
  where p.id = auth.uid()
    and (p.pin_seguro or p.correo not like '%@gestionrest.local')
$$;

-- =====================================================================
-- 4 · Limpieza diaria
-- =====================================================================
create or replace function public.limpiar_seguridad()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.eventos_seguridad where momento < now() - interval '180 days';
  delete from public.fichaje_intentos where momento < now() - interval '1 day';
$$;
revoke execute on function public.limpiar_seguridad() from public, anon, authenticated;

-- Cada día a las 04:17 (si pg_cron está activado; si no, actívalo en Database › Extensions y
-- vuelve a ejecutar este bloque)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('limpiar-seguridad', '17 4 * * *', 'select public.limpiar_seguridad()');
  else
    raise notice 'pg_cron no está activado: la limpieza diaria no queda programada';
  end if;
end $$;
