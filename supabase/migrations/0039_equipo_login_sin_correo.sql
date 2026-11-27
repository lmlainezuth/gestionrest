-- 0039 · equipo_login ya no da el correo interno del equipo (auditoría 27/11/2026).
-- EJECUTAR SOLO DESPUÉS de la 0038 y de instalar la app nueva en TODOS los equipos del bar:
-- las versiones antiguas entran con el correo que daba esta función y dejarían de poder entrar con PIN.
-- La pantalla de entrada solo necesita id, nombre y rol; el correo lo da correo_pin con el PIN correcto.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- Cambia lo que devuelve: hay que borrarla y volver a crearla
drop function if exists public.equipo_login(uuid);
create function public.equipo_login(p_empresa uuid)
returns table (id uuid, nombre text, rol text)
language sql stable security definer
set search_path = ''
as $$
  select p.id, p.nombre, eu.rol
  from public.empresa_usuarios eu join public.perfiles p on p.id = eu.usuario_id
  where eu.empresa_id = p_empresa and eu.activo and p.correo like '%@gestionrest.local'
  order by p.nombre
$$;
revoke all on function public.equipo_login(uuid) from public;
grant execute on function public.equipo_login(uuid) to anon, authenticated;
