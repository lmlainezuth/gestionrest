-- 0046 · Panel de plataforma: seguridad de TODOS los bares, solo para programadores (27/11/2026).
-- Lo ve el programador en Ajustes › Plataforma. Junta en una llamada:
--  · por bar: PIN incorrectos y bloqueos, intentos rechazados, cobros en turno cerrado, anulaciones,
--    descuadres, última copia en Drive y copias fallidas;
--  · cuentas de usuario sin ningún bar (si aparecen, alguien se está registrando por su cuenta:
--    revisa que el registro abierto esté desactivado en Supabase › Authentication);
--  · inicios de sesión por día y las IP con más inicios (del registro de Supabase Auth, si está activo);
--  · tamaño de la base frente al límite del plan.
-- Necesita la 0045. Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

create or replace function public.resumen_plataforma(p_dias int default 7)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_desde timestamptz := now() - make_interval(days => least(greatest(coalesce(p_dias, 7), 1), 90));
  v_bares jsonb;
  v_sin_bar jsonb;
  v_altas int;
  v_eventos jsonb;
  v_accesos jsonb := null;
  v_ips jsonb := null;
begin
  if not public.es_programador() then
    raise exception 'Solo para programadores';
  end if;

  select coalesce(jsonb_agg(b order by (b->>'alarmas')::int desc, b->>'nombre'), '[]'::jsonb) into v_bares
  from (
    select jsonb_build_object(
      'id', e.id, 'nombre', e.nombre,
      'usuarios', (select count(*) from public.empresa_usuarios u where u.empresa_id = e.id and u.activo),
      'pin_fallidos', s.pin_fallidos, 'pin_bloqueos', s.pin_bloqueos, 'rechazos', s.rechazos,
      'pin_max_persona', s.pin_max,
      'cobros_fuera_turno', c.fuera_turno, 'anulaciones', c.anulaciones, 'anulado_importe', c.importe,
      'descuadres', (select count(*) from public.turnos_caja t
                      where t.empresa_id = e.id and t.estado = 'cerrado' and t.cerrado_en >= v_desde
                        and abs(coalesce(t.diferencia, 0)) >= 1),
      'ultima_copia', (select max(k.creado_en) from public.copias_seguridad k where k.empresa_id = e.id and k.estado = 'ok'),
      'copias_error', (select count(*) from public.copias_seguridad k
                        where k.empresa_id = e.id and k.estado = 'error' and k.creado_en >= v_desde),
      'alarmas', s.pin_bloqueos + s.rechazos + c.fuera_turno + (case when s.pin_max >= 10 then 1 else 0 end)
    ) as b
    from public.empresa e
    cross join lateral (
      select count(*) filter (where ev.tipo = 'pin_fallido') as pin_fallidos,
             count(*) filter (where ev.tipo = 'pin_bloqueado') as pin_bloqueos,
             count(*) filter (where ev.tipo not in ('pin_fallido', 'pin_bloqueado')) as rechazos,
             coalesce((select max(n) from (select count(*) as n from public.eventos_seguridad x
                                            where x.empresa_id = e.id and x.momento >= v_desde and x.tipo = 'pin_fallido'
                                            group by x.usuario_id) m), 0) as pin_max
        from public.eventos_seguridad ev
       where ev.empresa_id = e.id and ev.momento >= v_desde) s
    cross join lateral (
      select count(*) filter (where a.tipo = 'cobro_fuera_turno') as fuera_turno,
             count(*) filter (where a.tipo <> 'cobro_fuera_turno') as anulaciones,
             coalesce(sum(a.importe) filter (where a.tipo <> 'cobro_fuera_turno'), 0) as importe
        from public.registro_anulaciones a
       where a.empresa_id = e.id and a.momento >= v_desde) c
  ) x;

  -- Cuentas sin ningún bar (ni programadores): con el registro abierto, cualquiera puede crearse una
  select coalesce(jsonb_agg(jsonb_build_object('correo', u.email, 'creado', u.created_at, 'ultimo_acceso', u.last_sign_in_at)
                            order by u.created_at desc), '[]'::jsonb)
    into v_sin_bar
    from (select au.email, au.created_at, au.last_sign_in_at from auth.users au
           where not exists (select 1 from public.empresa_usuarios eu where eu.usuario_id = au.id)
             and not exists (select 1 from public.programadores p where p.usuario_id = au.id)
           order by au.created_at desc limit 20) u;
  select count(*) into v_altas from auth.users au where au.created_at >= v_desde;

  -- Últimos intentos rechazados de todos los bares
  select coalesce(jsonb_agg(jsonb_build_object('bar', em.nombre, 'tipo', ev.tipo, 'momento', ev.momento,
                                               'quien', pf.nombre, 'detalle', ev.detalle) order by ev.momento desc), '[]'::jsonb)
    into v_eventos
    from (select * from public.eventos_seguridad
           where momento >= v_desde and tipo not in ('pin_fallido')
           order by momento desc limit 100) ev
    left join public.empresa em on em.id = ev.empresa_id
    left join public.perfiles pf on pf.id = ev.usuario_id;

  -- Inicios de sesión (registro de auditoría de Supabase Auth; puede no existir o estar vacío)
  begin
    select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia, 'n', d.n) order by d.dia), '[]'::jsonb) into v_accesos
      from (select date_trunc('day', a.created_at)::date as dia, count(*) as n
              from auth.audit_log_entries a
             where a.created_at >= v_desde and a.payload->>'action' = 'login'
             group by 1) d;
    select coalesce(jsonb_agg(jsonb_build_object('ip', i.ip, 'n', i.n) order by i.n desc), '[]'::jsonb) into v_ips
      from (select a.ip_address as ip, count(*) as n
              from auth.audit_log_entries a
             where a.created_at >= v_desde and a.payload->>'action' = 'login' and coalesce(a.ip_address, '') <> ''
             group by 1 order by 2 desc limit 10) i;
  exception when others then
    v_accesos := null;
    v_ips := null;
  end;

  return jsonb_build_object(
    'desde', v_desde,
    'bares', v_bares,
    'cuentas_sin_bar', v_sin_bar,
    'altas', v_altas,
    'eventos', v_eventos,
    'accesos', v_accesos,
    'ips', v_ips,
    'base_bytes', pg_database_size(current_database()),
    'base_limite', 500 * 1024 * 1024  -- plan gratuito; cámbialo si el plan es otro
  );
end $$;
revoke all on function public.resumen_plataforma(int) from public, anon;
grant execute on function public.resumen_plataforma(int) to authenticated;
