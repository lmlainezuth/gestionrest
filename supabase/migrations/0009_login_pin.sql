-- Equipo que aparece en la pantalla de entrada (acceso con PIN).
-- Solo nombre, rol y el correo interno: nada más del perfil.
create or replace function public.equipo_login()
returns table (id uuid, nombre text, rol text, correo text)
language sql stable security definer
set search_path = ''
as $$
  select p.id, p.nombre, p.rol, p.correo
  from public.perfiles p
  where p.activo and p.correo like '%@gestionrest.local'
  order by p.nombre
$$;
grant execute on function public.equipo_login() to anon, authenticated;
