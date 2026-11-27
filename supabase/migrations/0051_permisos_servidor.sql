-- 0051 · Permisos en el servidor (informe de seguridad run-2, pistas 9, 11 y 12).
--  · El camarero necesita en la base el permiso que le marca el administrador para: cobrar,
--    anular, abrir caja (y el fondo sugerido), stock y mesas o barra (crear cuentas). El total del
--    día y los informes siguen con sus permisos.
--  · Cuadre ciego: sin el permiso de cierres, el camarero no lee el turno (solo con la función
--    turno_abierto, sin el fondo salvo que lo abriera él), ve solo sus movimientos de caja y sus
--    propias cuentas cobradas (las abiertas, todas), y de las facturas recientes solo las suyas.
--  · Un bar no se queda sin administrador activo, y cada cambio de rol, permisos o baja de un
--    miembro queda en eventos_seguridad. (El cambio de PIN entre administradores lo limita la
--    función crear-usuario.)
-- ORDEN: la app nueva en todos los equipos ANTES de esta migración (la antigua lee el turno
-- directamente y dejaría de ver la caja abierta). Ejecutar entero en el SQL Editor. Se puede
-- ejecutar más de una vez.

-- =====================================================================
-- 1 · Cobrar, anular, abrir caja, stock, mesas y barra
-- =====================================================================
drop policy if exists "camarero_pagos" on public.pagos;
create policy "camarero_pagos" on public.pagos for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero' and importe > 0 and (select public.tengo_permiso('cobrar')));

drop policy if exists "camarero_abrir_turno" on public.turnos_caja;
create policy "camarero_abrir_turno" on public.turnos_caja for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero' and usuario_id = (select auth.uid()) and estado = 'abierto'
              and (select public.tengo_permiso('caja')));

do $$
declare t text;
begin
  foreach t in array array['articulos_stock','escandallos','movimientos_stock'] loop
    execute format('drop policy if exists "escribir_%1$s" on public.%1$I', t);
    execute format('create policy "escribir_%1$s" on public.%1$I for insert to authenticated
                    with check ((select public.mi_rol()) = ''admin''
                                or ((select public.mi_rol()) = ''camarero'' and (select public.tengo_permiso(''stock''))))', t);
  end loop;
end $$;
drop policy if exists "editar_articulos_stock" on public.articulos_stock;
create policy "editar_articulos_stock" on public.articulos_stock for update to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('stock'))))
  with check ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('stock'))));
drop policy if exists "editar_escandallos" on public.escandallos;
create policy "editar_escandallos" on public.escandallos for update to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('stock'))))
  with check ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('stock'))));
drop policy if exists "borrar_escandallos" on public.escandallos;
create policy "borrar_escandallos" on public.escandallos for delete to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('stock'))));

-- Anular platos y cuentas, y crear cuentas de mesa o de barra: con su permiso
create or replace function public.permisos_camarero_pedidos()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'authenticated' or coalesce(public.mi_rol(), '') <> 'camarero' then
    return new;
  end if;
  if tg_table_name = 'pedido_detalle' then
    if new.estado_cocina = 'anulado' and old.estado_cocina is distinct from 'anulado'
       and not public.tengo_permiso('anular') then
      raise exception 'No tienes permiso para anular';
    end if;
  elsif tg_op = 'INSERT' then
    if new.tipo = 'barra' and not public.tengo_permiso('barra') then
      raise exception 'No tienes permiso para la barra';
    end if;
    if new.tipo <> 'barra' and not public.tengo_permiso('mesas') then
      raise exception 'No tienes permiso para mesas';
    end if;
  elsif new.estado = 'anulado' and old.estado is distinct from 'anulado' and not public.tengo_permiso('anular') then
    raise exception 'No tienes permiso para anular';
  end if;
  return new;
end $$;
drop trigger if exists permisos_camarero on public.pedido_detalle;
create trigger permisos_camarero before update on public.pedido_detalle
for each row execute function public.permisos_camarero_pedidos();
drop trigger if exists permisos_camarero on public.pedidos;
create trigger permisos_camarero before insert or update on public.pedidos
for each row execute function public.permisos_camarero_pedidos();

-- =====================================================================
-- 2 · Cuadre ciego: lo que ve el camarero del turno abierto
-- =====================================================================
drop policy if exists "camarero_ver_turnos" on public.turnos_caja;
create policy "camarero_ver_turnos" on public.turnos_caja for select to authenticated
  using ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('cierres')));

-- Turno abierto de una caja, para cobrar y cerrar. El fondo solo si lo abrió él (ya lo sabe) o
-- tiene el permiso de cierres
create or replace function public.turno_abierto(p_caja uuid)
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'id', t.id, 'caja_id', t.caja_id, 'usuario_id', t.usuario_id, 'abierto_en', t.abierto_en,
           'estado', t.estado,
           'efectivo_inicial', case when (select public.mi_rol()) = 'admin' or t.usuario_id = auth.uid()
                                         or (select public.tengo_permiso('cierres'))
                                    then t.efectivo_inicial end)
    from public.turnos_caja t
   where t.caja_id = p_caja and t.estado = 'abierto'
     and t.empresa_id = (select public.empresa_actual())
     and (select public.mi_rol()) in ('admin', 'camarero')
   limit 1
$$;
revoke all on function public.turno_abierto(uuid) from public, anon;
grant execute on function public.turno_abierto(uuid) to authenticated;

-- Fondo sugerido al abrir: hace falta el permiso de caja; con qué abrió el anterior, solo con cierres
drop function if exists public.fondo_sugerido(uuid);
create function public.fondo_sugerido(p_caja uuid)
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
           'dejado', t.fondo_siguiente,
           'inicial', case when (select public.mi_rol()) = 'admin' or (select public.tengo_permiso('cierres'))
                           then t.efectivo_inicial end)
    from public.turnos_caja t
   where t.caja_id = p_caja and t.empresa_id = (select public.empresa_actual())
     and (select public.mi_rol()) in ('admin', 'camarero')
     and (select public.tengo_permiso('caja'))
   order by t.abierto_en desc
   limit 1
$$;
revoke all on function public.fondo_sugerido(uuid) from public, anon;
grant execute on function public.fondo_sugerido(uuid) to authenticated;

-- Movimientos de caja: los suyos (con cierres, todos)
drop policy if exists "camarero_ver_mov_caja" on public.movimientos_caja;
create policy "camarero_ver_mov_caja" on public.movimientos_caja for select to authenticated
  using ((select public.mi_rol()) = 'camarero'
         and (usuario_id = (select auth.uid()) or (select public.tengo_permiso('cierres'))));

-- Cuentas: el camarero ve las abiertas y las suyas; las cobradas de otros, con total del día,
-- informes, resumen o cierres. La cocina y el admin, todas.
drop policy if exists "leer_pedidos" on public.pedidos;
create policy "leer_pedidos" on public.pedidos for select to authenticated
  using ((select public.mi_rol()) in ('admin', 'cocinero')
         or ((select public.mi_rol()) = 'camarero' and (
               estado in ('abierto', 'precuenta') or camarero_id = (select auth.uid())
               or (select public.tengo_permiso('total_dia')) or (select public.tengo_permiso('informes'))
               or (select public.tengo_permiso('resumen')) or (select public.tengo_permiso('cierres')))));
-- Los platos, como su cuenta (la consulta corre con los permisos de quien lee)
drop policy if exists "leer_detalle" on public.pedido_detalle;
create policy "leer_detalle" on public.pedido_detalle for select to authenticated
  using ((select public.mi_rol()) in ('admin', 'cocinero')
         or ((select public.mi_rol()) = 'camarero' and exists (select 1 from public.pedidos p where p.id = pedido_id)));

-- Facturas recientes: sin el permiso de facturas o informes, solo las que hizo él
drop policy if exists "camarero_ver_facturas" on public.facturas;
create policy "camarero_ver_facturas" on public.facturas for select to authenticated
  using ((select public.mi_rol()) = 'camarero' and (
           (select public.tengo_permiso('facturas')) or (select public.tengo_permiso('informes'))
           or (fecha >= now() - interval '36 hours' and creado_por = (select auth.uid()))
           or estado_envio in ('pendiente', 'error')
           or exists (select 1 from public.pedidos p where p.id = pedido_id and p.estado <> 'pagado')));

-- =====================================================================
-- 3 · Miembros: nunca sin administrador, y cada cambio queda apuntado
-- =====================================================================
create or replace function public.miembros_vigilar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text;
begin
  -- Es security definer: el servidor (alta de usuarios, borrar un bar entero, SQL Editor) se
  -- reconoce por el rol de la sesión, no por current_user (que aquí es el dueño)
  if coalesce(auth.role(), '') <> 'authenticated' then
    return coalesce(new, old);
  end if;
  if old.rol = 'admin' and old.activo
     and (tg_op = 'DELETE' or new.rol <> 'admin' or not new.activo)
     and not exists (select 1 from public.empresa_usuarios eu
                      where eu.empresa_id = old.empresa_id and eu.usuario_id <> old.usuario_id
                        and eu.rol = 'admin' and eu.activo) then
    raise exception 'El bar no puede quedarse sin ningún administrador';
  end if;
  select p.nombre into v_nombre from public.perfiles p where p.id = old.usuario_id;
  if tg_op = 'DELETE' then
    insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
    values (old.empresa_id, 'miembro_cambiado', auth.uid(), format('Quitó del bar a %s (%s)', v_nombre, old.rol));
    return old;
  end if;
  if new.rol is distinct from old.rol or new.activo is distinct from old.activo
     or new.permisos is distinct from old.permisos then
    insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
    values (old.empresa_id, 'miembro_cambiado', auth.uid(),
            left(format('%s: rol %s → %s, activo %s → %s, permisos %s → %s', v_nombre, old.rol, new.rol,
                        old.activo, new.activo, old.permisos, new.permisos), 500));
  end if;
  return new;
end $$;
revoke all on function public.miembros_vigilar() from public, anon, authenticated;
drop trigger if exists miembros_vigilar on public.empresa_usuarios;
create trigger miembros_vigilar before update or delete on public.empresa_usuarios
for each row execute function public.miembros_vigilar();
