-- 0022 · Perfil de Gestión: ve nombres del equipo (cierres, ventas) sin datos de acceso.
-- El administrador sigue recibiendo correo y permisos; el resto, solo id, nombre, rol y activo.
create or replace function public.equipo_empresa()
returns table (id uuid, nombre text, correo text, rol text, activo boolean, permisos text[])
language sql stable security definer
set search_path = ''
as $$
  select p.id, p.nombre,
         case when public.mi_rol() = 'admin' then p.correo end,
         eu.rol, eu.activo,
         case when public.mi_rol() = 'admin' then eu.permisos end
  from public.empresa_usuarios eu join public.perfiles p on p.id = eu.usuario_id
  where eu.empresa_id = public.empresa_actual() and public.mi_rol() is not null
  order by eu.activo, p.nombre
$$;

-- Usuarios ya creados con el perfil de Gestión: se les añaden facturas, informes y cierres
update public.empresa_usuarios
   set permisos = array['caja_diaria','gastos','proveedores','resumen','stock','facturas','informes','cierres']
 where rol = 'camarero'
   and permisos is not null
   and permisos @> array['caja_diaria','gastos','proveedores','resumen','stock']
   and not permisos && array['mesas','barra','cobrar'];
