-- 0041 · Segunda tanda de arreglos de la auditoría (27/11/2026).
-- 1) El cocinero solo cambia el estado de cocina de un plato (no anula ni recupera, ni toca el IVA).
-- 2) La cadena TicketBAI: cada factura nueva tiene que encadenar con la ÚLTIMA de su serie en el bar.
-- 3) Cada bar puede pedir como mucho 50 series (no puede agotar las de otro titular poniendo su NIF).
-- 4) Un administrador no puede añadir a su bar usuarios de otros bares (las altas las hace crear-usuario).
-- 5) Para pasar a administrador hace falta un PIN de 6 cifras o más (lo apunta crear-usuario).
-- 6) Imágenes de productos: cada bar solo toca las de su carpeta (<id del bar>/...).
-- ORDEN: esta migración ANTES de desplegar la función crear-usuario nueva (escribe perfiles.pin_seguro).
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Cocinero: solo estado_cocina (sin anular ni desanular) y listo_en
-- =====================================================================
create or replace function public.limitar_cocinero()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.mi_rol() = 'cocinero' then
    if (to_jsonb(new) - 'estado_cocina' - 'listo_en') is distinct from (to_jsonb(old) - 'estado_cocina' - 'listo_en') then
      raise exception 'El cocinero solo puede cambiar el estado del plato';
    end if;
    if new.estado_cocina is distinct from old.estado_cocina
       and (new.estado_cocina = 'anulado' or old.estado_cocina = 'anulado') then
      raise exception 'El cocinero no puede anular platos ni recuperar los anulados';
    end if;
  end if;
  return new;
end $$;

-- =====================================================================
-- 2 · Cadena TicketBAI: anterior_id = la última de la serie (misma regla que tbai_ultima_factura)
-- =====================================================================
create or replace function public.factura_encadenada()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ultima uuid;
begin
  if new.legado then
    return new;
  end if;
  -- Reintento de una subida que ya llegó (ventas sin internet): lo resuelve el ON CONFLICT
  if exists (select 1 from public.facturas where id = new.id) then
    return new;
  end if;
  -- Dos emisiones a la vez en la misma serie esperan su turno
  perform pg_advisory_xact_lock(hashtext('tbai_cadena:' || new.empresa_id::text || ':' || new.cadena));
  select f.id into v_ultima
    from public.facturas f
   where f.cadena = new.cadena and f.empresa_id = new.empresa_id
     and not exists (select 1 from public.facturas g where g.anterior_id = f.id and g.empresa_id = new.empresa_id)
   order by f.legado, f.fecha desc, f.creado_en desc
   limit 1;
  if new.anterior_id is distinct from v_ultima then
    -- 23505: la app lo trata como "otro equipo emitió a la vez" y vuelve a leer la última
    raise exception 'La serie % ha avanzado mientras se emitía: vuelve a intentarlo', new.cadena
      using errcode = '23505';
  end if;
  return new;
end $$;
revoke all on function public.factura_encadenada() from public, anon, authenticated;
drop trigger if exists ab_factura_encadenada on public.facturas;
create trigger ab_factura_encadenada before insert on public.facturas
for each row execute function public.factura_encadenada();

-- =====================================================================
-- 3 · Series: como mucho 50 por bar
-- =====================================================================
create or replace function public.tbai_asignar_serie(p_tipo text, p_descripcion text default null)
returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  v_empresa uuid := public.empresa_actual();
  v_actual text;
begin
  if public.mi_rol() is distinct from 'admin' then
    raise exception 'Solo un administrador puede asignar series';
  end if;
  if p_tipo not in ('caja', 'equipo') then
    raise exception 'Tipo de serie no válido';
  end if;
  -- El espacio de series de un NIF es finito y compartido: un bar no puede gastar el de otro titular
  if (select count(*) from public.tbai_series s where s.empresa_id = v_empresa) >= 50 then
    raise exception 'Este bar ya tiene 50 series: pide ayuda al soporte si de verdad necesitas más';
  end if;
  -- En producción la caja no cambia de serie si ya factura con ella (con este mismo titular)
  if p_tipo = 'caja' then
    select c.serie_factura into v_actual from public.cajas c where c.empresa_id = v_empresa and c.activo limit 1;
    if exists (select 1 from public.tbai_series s
                 join public.tbai_config t on t.empresa_id = s.empresa_id
                where s.empresa_id = v_empresa and s.serie = v_actual and s.nif = t.nif
                  and s.entorno = 'produccion' and t.entorno = 'produccion')
       and exists (select 1 from public.facturas f where f.empresa_id = v_empresa and f.cadena = v_actual) then
      raise exception 'En producción no se cambia la serie de una caja que ya factura';
    end if;
  end if;
  return public.tbai_nueva_serie(v_empresa, p_tipo, p_descripcion);
end $$;
revoke all on function public.tbai_asignar_serie(text, text) from public, anon;
grant execute on function public.tbai_asignar_serie(text, text) to authenticated;

-- =====================================================================
-- 4 · Miembros: el administrador cambia rol/activo/permisos, pero no da de alta a nadie
-- =====================================================================
drop policy if exists "admin_miembros" on public.empresa_usuarios;
drop policy if exists "admin_miembros_cambiar" on public.empresa_usuarios;
drop policy if exists "admin_miembros_quitar" on public.empresa_usuarios;
create policy "admin_miembros_cambiar" on public.empresa_usuarios for update to authenticated
  using (empresa_id = (select public.empresa_actual()) and (select public.mi_rol()) = 'admin')
  with check (empresa_id = (select public.empresa_actual()) and (select public.mi_rol()) = 'admin');
create policy "admin_miembros_quitar" on public.empresa_usuarios for delete to authenticated
  using (empresa_id = (select public.empresa_actual()) and (select public.mi_rol()) = 'admin');

-- Una fila de miembro no cambia de usuario ni de bar
create or replace function public.miembro_fijo()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.usuario_id is distinct from old.usuario_id or new.empresa_id is distinct from old.empresa_id then
    raise exception 'No se puede cambiar el usuario ni el bar de un miembro';
  end if;
  return new;
end $$;
drop trigger if exists miembro_fijo on public.empresa_usuarios;
create trigger miembro_fijo before update on public.empresa_usuarios
for each row execute function public.miembro_fijo();

-- =====================================================================
-- 5 · PIN largo para pasar a administrador
-- =====================================================================
alter table public.perfiles add column if not exists pin_seguro boolean not null default false;

create or replace function public.admin_con_pin_seguro()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.rol = 'admin' and (tg_op = 'INSERT' or old.rol is distinct from 'admin')
     and exists (select 1 from public.perfiles p
                  where p.id = new.usuario_id and p.correo like '%@gestionrest.local' and not p.pin_seguro) then
    raise exception 'Para hacerle administrador, cámbiale antes el PIN a uno de 6 cifras o más';
  end if;
  return new;
end $$;
drop trigger if exists admin_con_pin_seguro on public.empresa_usuarios;
create trigger admin_con_pin_seguro before insert or update on public.empresa_usuarios
for each row execute function public.admin_con_pin_seguro();

-- =====================================================================
-- 6 · Imágenes de productos por carpeta del bar
-- =====================================================================
drop policy if exists "productos_img_leer" on storage.objects;
drop policy if exists "productos_img_subir" on storage.objects;
drop policy if exists "productos_img_cambiar" on storage.objects;
drop policy if exists "productos_img_borrar" on storage.objects;
-- Las imágenes se ven por su dirección pública (bucket público). Listar solo lo del propio bar.
create policy "productos_img_leer" on storage.objects for select to authenticated
  using (bucket_id = 'productos' and (storage.foldername(name))[1] = (select public.empresa_actual())::text);
create policy "productos_img_subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'productos' and (select public.mi_rol()) = 'admin'
              and (storage.foldername(name))[1] = (select public.empresa_actual())::text);
create policy "productos_img_cambiar" on storage.objects for update to authenticated
  using (bucket_id = 'productos' and (select public.mi_rol()) = 'admin'
         and (storage.foldername(name))[1] = (select public.empresa_actual())::text)
  with check (bucket_id = 'productos' and (select public.mi_rol()) = 'admin'
              and (storage.foldername(name))[1] = (select public.empresa_actual())::text);
create policy "productos_img_borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'productos' and (select public.mi_rol()) = 'admin'
         and (storage.foldername(name))[1] = (select public.empresa_actual())::text);
-- Las imágenes antiguas (sin carpeta) se siguen viendo, pero ya nadie las puede cambiar ni borrar.
