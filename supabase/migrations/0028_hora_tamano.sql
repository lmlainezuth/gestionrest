-- 0028 · Hora del servidor (para comprobar la del equipo) y tamaño de la base (panel).
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- Los tickets llevan la hora del equipo: la app la compara con esta al abrir caja
create or replace function public.hora_servidor()
returns timestamptz
language sql stable
set search_path = ''
as $$
  select now()
$$;
revoke all on function public.hora_servidor() from public, anon;
grant execute on function public.hora_servidor() to authenticated;

-- Plan gratuito: 500 MB. El panel avisa al 75 %: si se llena, la base deja de guardar ventas
create or replace function public.tamano_base()
returns bigint
language sql stable security definer
set search_path = ''
as $$
  select pg_database_size(current_database())
$$;
revoke all on function public.tamano_base() from public, anon;
grant execute on function public.tamano_base() to authenticated;
