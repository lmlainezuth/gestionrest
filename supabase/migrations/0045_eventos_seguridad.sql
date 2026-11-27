-- 0045 · Panel de seguridad y avisos (27/11/2026).
-- 1) eventos_seguridad: lo apuntan la base y las funciones del servidor (nunca la app): cada PIN
--    fallido, cada bloqueo por PIN, anulaciones que un camarero intentó firmar, intentos de tocar
--    usuarios de otro bar… Nadie lo puede escribir ni borrar desde la app.
-- 2) resumen_seguridad(): lo que ve el administrador en Números › Seguridad (solo su bar).
-- 3) El aviso diario por correo a la plataforma lo hace la función alertas-seguridad (ver al final).
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Tabla de eventos
-- =====================================================================
create table if not exists public.eventos_seguridad (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid references public.empresa(id) on delete cascade,
  momento     timestamptz not null default now(),
  tipo        text not null,
  usuario_id  uuid,
  detalle     text check (char_length(detalle) <= 500)
);
create index if not exists eventos_seguridad_idx on public.eventos_seguridad (empresa_id, momento desc);
create index if not exists eventos_seguridad_momento_idx on public.eventos_seguridad (momento desc);

alter table public.eventos_seguridad enable row level security;
drop policy if exists "admin_ver_eventos" on public.eventos_seguridad;
create policy "admin_ver_eventos" on public.eventos_seguridad for select to authenticated
  using (empresa_id = (select public.empresa_actual()) and (select public.mi_rol()) = 'admin');
-- Sin políticas de escritura: solo escriben las funciones del servidor
revoke all on public.eventos_seguridad from anon;

-- =====================================================================
-- 2 · Cada PIN fallido queda apuntado (y el bloqueo, cuando llega)
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
  if (select count(*) from public.fichaje_intentos
       where usuario_id = p_usuario and momento > now() - interval '5 minutes') >= 5 then
    raise exception 'Demasiados PIN incorrectos. Espera 5 minutos';
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
    insert into public.fichaje_intentos (usuario_id) values (p_usuario);
    insert into public.eventos_seguridad (empresa_id, tipo, usuario_id) values (p_empresa, 'pin_fallido', p_usuario);
    select count(*) into v_fallos from public.fichaje_intentos
     where usuario_id = p_usuario and momento > now() - interval '5 minutes';
    if v_fallos = 5 then
      insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
      values (p_empresa, 'pin_bloqueado', p_usuario, '5 PIN incorrectos seguidos: bloqueado 5 minutos');
    end if;
    return null;   -- sin excepción: si no, se desharía lo apuntado
  end if;
  delete from public.fichaje_intentos where usuario_id = p_usuario;
  return v_nombre;
end $$;
revoke execute on function public.fichaje_comprobar(uuid, uuid, text) from public, anon, authenticated;

-- =====================================================================
-- 3 · Resumen para el administrador (solo su bar)
-- =====================================================================
create or replace function public.resumen_seguridad(p_dias int default 7)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_empresa uuid := public.empresa_actual();
  v_desde timestamptz := now() - make_interval(days => least(greatest(coalesce(p_dias, 7), 1), 90));
begin
  if coalesce(public.mi_rol(), '') <> 'admin' then
    raise exception 'Solo el administrador';
  end if;
  return jsonb_build_object(
    'desde', v_desde,
    -- PIN fallidos y bloqueos por persona
    'pin', coalesce((
      select jsonb_agg(jsonb_build_object('usuario_id', x.usuario_id, 'fallidos', x.fallidos,
                                          'bloqueos', x.bloqueos, 'ultimo', x.ultimo) order by x.fallidos desc)
        from (select e.usuario_id,
                     count(*) filter (where e.tipo = 'pin_fallido') as fallidos,
                     count(*) filter (where e.tipo = 'pin_bloqueado') as bloqueos,
                     max(e.momento) as ultimo
                from public.eventos_seguridad e
               where e.empresa_id = v_empresa and e.momento >= v_desde and e.tipo in ('pin_fallido', 'pin_bloqueado')
               group by e.usuario_id) x), '[]'::jsonb),
    -- Otros eventos (anulaciones denegadas, intentos sobre usuarios de otro bar…), los últimos 50
    'eventos', coalesce((
      select jsonb_agg(jsonb_build_object('tipo', e.tipo, 'momento', e.momento, 'usuario_id', e.usuario_id,
                                          'detalle', e.detalle) order by e.momento desc)
        from (select * from public.eventos_seguridad
               where empresa_id = v_empresa and momento >= v_desde and tipo not in ('pin_fallido', 'pin_bloqueado')
               order by momento desc limit 50) e), '[]'::jsonb),
    -- Registro de control por persona y tipo (anulaciones, borrados, cobros en turno cerrado…)
    'control', coalesce((
      select jsonb_agg(jsonb_build_object('usuario_id', x.usuario_id, 'tipo', x.tipo, 'n', x.n, 'importe', x.importe)
                       order by x.importe desc)
        from (select a.usuario_id, a.tipo, count(*) as n, coalesce(sum(a.importe), 0) as importe
                from public.registro_anulaciones a
               where a.empresa_id = v_empresa and a.momento >= v_desde
               group by a.usuario_id, a.tipo) x), '[]'::jsonb),
    -- Cierres de caja que no cuadraron (1 € o más)
    'descuadres', coalesce((
      select jsonb_agg(jsonb_build_object('usuario_id', t.cerrado_por, 'cerrado_en', t.cerrado_en,
                                          'diferencia', t.diferencia) order by t.cerrado_en desc)
        from public.turnos_caja t
       where t.empresa_id = v_empresa and t.estado = 'cerrado' and t.cerrado_en >= v_desde
         and abs(coalesce(t.diferencia, 0)) >= 1), '[]'::jsonb),
    -- Fichajes sin internet que llegaron más de 10 minutos después de la hora fichada
    'fichajes_tarde', coalesce((
      select jsonb_agg(jsonb_build_object('usuario_id', x.usuario_id, 'n', x.n))
        from (select f.usuario_id, count(*) as n from public.fichajes f
               where f.empresa_id = v_empresa and f.origen = 'sin_conexion' and f.registrado_en >= v_desde
                 and f.registrado_en - f.momento > interval '10 minutes'
               group by f.usuario_id) x), '[]'::jsonb)
  );
end $$;
revoke all on function public.resumen_seguridad(int) from public, anon;
grant execute on function public.resumen_seguridad(int) to authenticated;

-- =====================================================================
-- 4 · Aviso diario por correo (función alertas-seguridad). Configurar UNA VEZ:
--   supabase secrets set AVISOS_CORREO=<tu correo>   (ya existe si lo usa la copia en Drive)
--   supabase functions deploy alertas-seguridad --no-verify-jwt
-- y programarla (como la copia diaria, con la clave anónima y el secreto COPIA_SECRETO):
-- =====================================================================
-- do $$ begin
--   if exists (select 1 from cron.job where jobname = 'alertas-seguridad') then
--     perform cron.unschedule('alertas-seguridad');
--   end if;
-- end $$;
-- select cron.schedule('alertas-seguridad', '0 7 * * *', $cron$
--   select net.http_post(
--     url := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/alertas-seguridad',
--     headers := jsonb_build_object('Content-Type', 'application/json',
--                                   'Authorization', 'Bearer TU_CLAVE_ANON',
--                                   'x-copia-secreto', 'TU_SECRETO'),
--     body := '{}'::jsonb,
--     timeout_milliseconds := 60000)
-- $cron$);
