-- 0043 · Permisos en la base, cuadre ciego de verdad y cuentas solo por el servidor (auditoría 27/11/2026).
-- 1) Los permisos que el administrador quita a un camarero (caja, gastos, facturas, informes…) ya no
--    son solo de la pantalla: la base también los aplica (función tengo_permiso, mismas reglas que
--    lib/core/permisos.dart). Al administrador la base no le limita nada.
-- 2) Cuadre ciego: el camarero no lee los cobros (pagos) ni los turnos ya cerrados, salvo que tenga
--    los permisos de informes/resumen o de cierres. El resultado del cierre (ventas por forma de pago
--    y tickets) lo devuelve cerrar_caja_ciego DESPUÉS de cerrar, para imprimirlo.
-- 3) Unir mesas, dividir la cuenta y cancelar un reparto solo por funciones del servidor. Directamente,
--    un camarero ya no puede cambiar cantidades, precios ni pasar platos de una cuenta a otra, ni
--    dejar una cuenta "unida" (eso servía para quitar consumiciones sin que quedara rastro).
-- Necesita la app nueva (usa las funciones nuevas). Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 0 · ¿Tiene el usuario este permiso en su bar actual?
-- =====================================================================
create or replace function public.tengo_permiso(p text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce((
    select case
      when eu.rol = 'admin' then true
      when eu.rol = 'camarero' then
        p = any (array['mesas','barra','cobrar','anular','caja','gastos','proveedores','resumen','stock',
                       'total_dia','facturas','informes','cierres'])
        and p = any (coalesce(eu.permisos, array['mesas','barra','cobrar','anular']))
      when eu.rol = 'cocinero' then p = 'cocina' and p = any (coalesce(eu.permisos, array['cocina']))
      else false
    end
    from public.perfiles pf
    join public.empresa_usuarios eu on eu.usuario_id = pf.id and eu.empresa_id = pf.empresa_actual and eu.activo
    where pf.id = auth.uid()), false)
$$;
revoke all on function public.tengo_permiso(text) from public, anon;
grant execute on function public.tengo_permiso(text) to authenticated;

-- =====================================================================
-- 1 · Gastos, proveedores y caja diaria según permisos
-- =====================================================================
drop policy if exists "leer_gastos" on public.gastos;
drop policy if exists "escribir_gastos" on public.gastos;
drop policy if exists "editar_gastos" on public.gastos;
create policy "leer_gastos" on public.gastos for select to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and
         ((select public.tengo_permiso('gastos')) or (select public.tengo_permiso('proveedores'))
          or (select public.tengo_permiso('resumen')) or (select public.tengo_permiso('informes')))));
create policy "escribir_gastos" on public.gastos for insert to authenticated
  with check ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and
              ((select public.tengo_permiso('gastos')) or (select public.tengo_permiso('stock')))));
create policy "editar_gastos" on public.gastos for update to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('gastos'))))
  with check ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('gastos'))));

drop policy if exists "leer_proveedores" on public.proveedores;
drop policy if exists "escribir_proveedores" on public.proveedores;
drop policy if exists "editar_proveedores" on public.proveedores;
create policy "leer_proveedores" on public.proveedores for select to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and
         ((select public.tengo_permiso('proveedores')) or (select public.tengo_permiso('gastos'))
          or (select public.tengo_permiso('stock')) or (select public.tengo_permiso('resumen')))));
create policy "escribir_proveedores" on public.proveedores for insert to authenticated
  with check ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and
              ((select public.tengo_permiso('proveedores')) or (select public.tengo_permiso('gastos')))));
create policy "editar_proveedores" on public.proveedores for update to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and
         ((select public.tengo_permiso('proveedores')) or (select public.tengo_permiso('gastos')))))
  with check ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and
              ((select public.tengo_permiso('proveedores')) or (select public.tengo_permiso('gastos')))));

drop policy if exists "leer_cajas_diarias" on public.cajas_diarias;
drop policy if exists "escribir_cajas_diarias" on public.cajas_diarias;
drop policy if exists "editar_cajas_diarias" on public.cajas_diarias;
create policy "leer_cajas_diarias" on public.cajas_diarias for select to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and
         ((select public.tengo_permiso('caja')) or (select public.tengo_permiso('resumen')) or (select public.tengo_permiso('informes')))));
create policy "escribir_cajas_diarias" on public.cajas_diarias for insert to authenticated
  with check ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('caja'))));
create policy "editar_cajas_diarias" on public.cajas_diarias for update to authenticated
  using ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('caja'))))
  with check ((select public.mi_rol()) = 'admin' or ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('caja'))));

-- Ingresos y gastos de caja: solo con el permiso de caja
drop policy if exists "camarero_mov_caja" on public.movimientos_caja;
create policy "camarero_mov_caja" on public.movimientos_caja for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero' and (select public.tengo_permiso('caja'))
              and usuario_id = (select auth.uid())
              and exists (select 1 from public.turnos_caja t where t.id = turno_id and t.estado = 'abierto'));

-- =====================================================================
-- 2 · Facturas: sin el permiso de facturas (o informes), el camarero solo ve las recientes, las
--     pendientes de envío y las de cuentas aún sin cobrar (lo que necesita para cobrar y reenviar)
-- =====================================================================
drop policy if exists "camarero_ver_facturas" on public.facturas;
create policy "camarero_ver_facturas" on public.facturas for select to authenticated
  using ((select public.mi_rol()) = 'camarero' and (
           (select public.tengo_permiso('facturas')) or (select public.tengo_permiso('informes'))
           or fecha >= now() - interval '36 hours'
           or estado_envio in ('pendiente', 'error')
           or exists (select 1 from public.pedidos p where p.id = pedido_id and p.estado <> 'pagado')));

-- La cadena y la numeración miran TODAS las facturas de la serie del bar, las vea o no quien emite
create or replace function public.tbai_ultima_factura(p_cadena text)
returns setof public.facturas
language sql stable
security definer
set search_path = ''
as $$
  select f.* from public.facturas f
   where f.cadena = p_cadena
     and f.empresa_id = (select public.empresa_actual())
     and (select public.mi_rol()) is not null
     and not exists (select 1 from public.facturas g where g.anterior_id = f.id and g.empresa_id = f.empresa_id)
   order by f.legado, f.fecha desc, f.creado_en desc
   limit 1
$$;
revoke all on function public.tbai_ultima_factura(text) from public, anon;
grant execute on function public.tbai_ultima_factura(text) to authenticated;

create or replace function public.tbai_ultimo_numero(p_serie text)
returns int
language sql stable
security definer
set search_path = ''
as $$
  select max(f.numero) from public.facturas f
   where f.serie = p_serie and f.empresa_id = (select public.empresa_actual())
     and (select public.mi_rol()) is not null
$$;
revoke all on function public.tbai_ultimo_numero(text) from public, anon;
grant execute on function public.tbai_ultimo_numero(text) to authenticated;

-- =====================================================================
-- 3 · Cuadre ciego: cobros y turnos cerrados
-- =====================================================================
drop policy if exists "camarero_ver_pagos" on public.pagos;
create policy "camarero_ver_pagos" on public.pagos for select to authenticated
  using ((select public.mi_rol()) = 'camarero' and (
           (select public.tengo_permiso('informes')) or (select public.tengo_permiso('resumen'))
           or ((select public.tengo_permiso('cierres'))
               and exists (select 1 from public.turnos_caja t where t.id = turno_id and t.estado = 'cerrado'))));

drop policy if exists "camarero_ver_turnos" on public.turnos_caja;
create policy "camarero_ver_turnos" on public.turnos_caja for select to authenticated
  using ((select public.mi_rol()) = 'camarero' and (estado = 'abierto' or (select public.tengo_permiso('cierres'))));

-- Fondo que se propone al abrir la caja (lo que se dejó en el cajón la última vez)
-- {dejado: lo que se dejó al cerrar (o null), inicial: con lo que abrió el último turno}
drop function if exists public.fondo_sugerido(uuid);
create function public.fondo_sugerido(p_caja uuid)
returns jsonb
language sql stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('dejado', t.fondo_siguiente, 'inicial', t.efectivo_inicial)
    from public.turnos_caja t
   where t.caja_id = p_caja and t.empresa_id = (select public.empresa_actual())
     and (select public.mi_rol()) in ('admin', 'camarero')
   order by t.abierto_en desc
   limit 1
$$;
revoke all on function public.fondo_sugerido(uuid) from public, anon;
grant execute on function public.fondo_sugerido(uuid) to authenticated;

-- Cierre: solo con el permiso de caja; devuelve también las ventas por forma de pago y los tickets
create or replace function public.cerrar_caja_ciego(p_turno uuid, p_efectivo numeric, p_conteo jsonb default null,
                                                   p_tarjeta numeric default null, p_nota text default null,
                                                   p_fondo numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.turnos_caja;
  v_esp numeric;
  v_tar numeric;
  v_ing numeric;
  v_gas numeric;
  v_q_uds numeric;
  v_q_imp numeric;
  v_anul jsonb;
  v_ventas jsonb;
  v_tickets int;
begin
  if coalesce(public.mi_rol(), '') <> 'admin'
     and not (public.mi_rol() = 'camarero' and public.tengo_permiso('caja')) then
    raise exception 'No puedes cerrar la caja';
  end if;
  select * into t from public.turnos_caja
   where id = p_turno and empresa_id = (select public.empresa_actual()) for update;
  if t.id is null then raise exception 'Turno no encontrado'; end if;
  if t.estado <> 'abierto' then raise exception 'Este turno ya está cerrado'; end if;
  if p_efectivo is null or p_efectivo < 0 then raise exception 'Importe contado no válido'; end if;
  if p_fondo is not null and (p_fondo < 0 or p_fondo > p_efectivo) then
    raise exception 'El fondo que se deja no puede ser mayor que lo contado';
  end if;

  select t.efectivo_inicial
         + coalesce((select sum(p.importe) from public.pagos p where p.turno_id = t.id and p.metodo = 'efectivo'), 0)
         + coalesce((select sum(case m.tipo when 'ingreso' then m.importe else -m.importe end)
                       from public.movimientos_caja m where m.turno_id = t.id), 0)
    into v_esp;
  select coalesce(sum(p.importe), 0) into v_tar from public.pagos p where p.turno_id = t.id and p.metodo = 'tarjeta';

  perform set_config('gestionrest.cierre_ciego', '1', true);
  update public.turnos_caja set
    estado = 'cerrado',
    cerrado_en = now(),
    cerrado_por = auth.uid(),
    efectivo_calculado = v_esp,
    efectivo_real = p_efectivo,
    diferencia = p_efectivo - v_esp,
    conteo = p_conteo,
    tarjeta_calculado = v_tar,
    tarjeta_real = p_tarjeta,
    tarjeta_diferencia = case when p_tarjeta is null then null else p_tarjeta - v_tar end,
    nota = nullif(concat_ws(' · ', t.nota, nullif(trim(p_nota), '')), ''),  -- conserva la nota de apertura
    fondo_siguiente = p_fondo
  where id = t.id;
  perform set_config('gestionrest.cierre_ciego', '', true);

  -- El recuento ya está guardado y no se puede cambiar: ahora sí se devuelve el resultado a quien
  -- cierra (camarero incluido), con lo necesario para imprimir el cierre completo.
  select coalesce(sum(m.importe) filter (where m.tipo = 'ingreso'), 0),
         coalesce(sum(m.importe) filter (where m.tipo = 'gasto'), 0)
    into v_ing, v_gas from public.movimientos_caja m where m.turno_id = t.id;
  select coalesce(sum(a.cantidad), 0), coalesce(sum(a.importe), 0) into v_q_uds, v_q_imp
    from public.registro_anulaciones a
   where a.empresa_id = t.empresa_id and a.tipo = 'quitado_antes_cobrar' and a.momento >= t.abierto_en;
  select coalesce(jsonb_agg(jsonb_build_object('tipo', x.tipo, 'n', x.n, 'importe', x.importe) order by x.tipo), '[]'::jsonb)
    into v_anul
    from (select a.tipo, count(*) as n, coalesce(sum(a.importe), 0) as importe
            from public.registro_anulaciones a
           where a.empresa_id = t.empresa_id and a.tipo <> 'quitado_antes_cobrar' and a.momento >= t.abierto_en
           group by a.tipo) x;
  select coalesce(jsonb_object_agg(x.metodo, x.importe), '{}'::jsonb) into v_ventas
    from (select p.metodo, sum(p.importe) as importe from public.pagos p where p.turno_id = t.id group by p.metodo) x;
  select count(distinct p.pedido_id) into v_tickets from public.pagos p where p.turno_id = t.id and p.importe > 0;
  return jsonb_build_object('ok', true, 'esperado', v_esp, 'contado', p_efectivo, 'diferencia', p_efectivo - v_esp,
                            'tarjeta_esperado', v_tar, 'tarjeta_contado', p_tarjeta,
                            'tarjeta_diferencia', case when p_tarjeta is null then null else p_tarjeta - v_tar end,
                            'ingresos', v_ing, 'gastos', v_gas,
                            'quitados_uds', v_q_uds, 'quitados_importe', v_q_imp,
                            'anulaciones', v_anul, 'ventas', v_ventas, 'tickets', v_tickets);
end $$;
revoke all on function public.cerrar_caja_ciego(uuid, numeric, jsonb, numeric, text, numeric) from public, anon;
grant execute on function public.cerrar_caja_ciego(uuid, numeric, jsonb, numeric, text, numeric) to authenticated;

-- Tickets del turno para el camarero (sin importes)
create or replace function public.tickets_del_turno(p_turno uuid)
returns int
language sql stable
security definer
set search_path = ''
as $$
  select count(distinct p.pedido_id)::int from public.pagos p
   where p.turno_id = p_turno and p.empresa_id = (select public.empresa_actual()) and p.importe > 0
     and (select public.mi_rol()) in ('admin', 'camarero')
$$;
revoke all on function public.tickets_del_turno(uuid) from public, anon;
grant execute on function public.tickets_del_turno(uuid) to authenticated;

-- =====================================================================
-- 4 · Cuentas: unir, dividir y cancelar el reparto solo por el servidor
-- =====================================================================
alter table public.pedido_detalle add column if not exists reparto_de uuid references public.pedido_detalle(id) on delete set null;

create or replace function public.cuenta_abierta(p_pedido uuid)
returns public.pedidos
language plpgsql security definer
set search_path = ''
as $$
declare
  v public.pedidos;
begin
  if coalesce(public.mi_rol(), '') not in ('admin', 'camarero') then
    raise exception 'No puedes cambiar cuentas';
  end if;
  select * into v from public.pedidos
   where id = p_pedido and empresa_id = (select public.empresa_actual()) for update;
  if v.id is null then raise exception 'Cuenta no encontrada'; end if;
  if v.estado not in ('abierto', 'precuenta') then raise exception 'Esa cuenta ya no está abierta'; end if;
  return v;
end $$;
revoke all on function public.cuenta_abierta(uuid) from public, anon, authenticated;

-- Une la cuenta p_origen a p_destino (p_origen queda "unida")
create or replace function public.unir_cuentas(p_destino uuid, p_origen uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  if p_destino = p_origen then raise exception 'Elige otra cuenta'; end if;
  perform public.cuenta_abierta(p_destino);
  perform public.cuenta_abierta(p_origen);
  update public.pedido_detalle set pedido_id = p_destino where pedido_id = p_origen;
  update public.pedidos set estado = 'unido' where id = p_origen;
end $$;
revoke all on function public.unir_cuentas(uuid, uuid) from public, anon;
grant execute on function public.unir_cuentas(uuid, uuid) to authenticated;

-- Pasa a una cuenta nueva lo que paga una persona. p_lineas: [{"id": <línea>, "cantidad": <n>}]
create or replace function public.repartir_cuenta(p_pedido uuid, p_lineas jsonb)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v_ped public.pedidos := public.cuenta_abierta(p_pedido);
  v_nuevo uuid;
  x jsonb;
  v_lin public.pedido_detalle;
  v_k numeric;
begin
  if p_lineas is null or jsonb_typeof(p_lineas) <> 'array' then raise exception 'Faltan los platos'; end if;
  insert into public.pedidos (empresa_id, tipo, mesa_id, nombre_llevar, camarero_id, num_personas)
  values (v_ped.empresa_id, v_ped.tipo, v_ped.mesa_id, v_ped.nombre_llevar, auth.uid(), 1)
  returning id into v_nuevo;
  for x in select * from jsonb_array_elements(p_lineas) loop
    v_k := (x->>'cantidad')::numeric;
    continue when v_k is null or v_k <= 0;
    select * into v_lin from public.pedido_detalle
     where id = (x->>'id')::uuid and pedido_id = p_pedido and estado_cocina <> 'anulado' for update;
    if v_lin.id is null then raise exception 'Ese plato ya no está en la cuenta'; end if;
    if v_k > v_lin.cantidad then raise exception 'No hay tantas unidades de %', v_lin.descripcion; end if;
    if v_k = v_lin.cantidad then
      update public.pedido_detalle set pedido_id = v_nuevo where id = v_lin.id;
    else
      update public.pedido_detalle set cantidad = cantidad - v_k where id = v_lin.id;
      insert into public.pedido_detalle
        (empresa_id, pedido_id, producto_id, area_id, descripcion, cantidad, precio_unitario, tipo_iva,
         nota, curso, estado_cocina, en_espera, reparto_de)
      values (v_lin.empresa_id, v_nuevo, v_lin.producto_id, v_lin.area_id, v_lin.descripcion, v_k,
              v_lin.precio_unitario, v_lin.tipo_iva, v_lin.nota, v_lin.curso, v_lin.estado_cocina,
              v_lin.en_espera, v_lin.id);
    end if;
  end loop;
  if not exists (select 1 from public.pedido_detalle where pedido_id = v_nuevo) then
    raise exception 'Elige lo que paga esta persona';
  end if;
  return v_nuevo;
end $$;
revoke all on function public.repartir_cuenta(uuid, jsonb) from public, anon;
grant execute on function public.repartir_cuenta(uuid, jsonb) to authenticated;

-- Deshace un reparto sin cobrar: todo vuelve a la cuenta original
create or replace function public.cancelar_reparto(p_nuevo uuid, p_original uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_lin public.pedido_detalle;
begin
  perform public.cuenta_abierta(p_original);
  perform public.cuenta_abierta(p_nuevo);
  for v_lin in select * from public.pedido_detalle where pedido_id = p_nuevo for update loop
    if v_lin.reparto_de is not null
       and exists (select 1 from public.pedido_detalle o where o.id = v_lin.reparto_de and o.pedido_id = p_original) then
      update public.pedido_detalle set cantidad = cantidad + v_lin.cantidad where id = v_lin.reparto_de;
    else
      update public.pedido_detalle set pedido_id = p_original where id = v_lin.id;
    end if;
  end loop;
  -- Primero "unida" y luego se borran las copias: no es una anulación
  update public.pedidos set estado = 'unido' where id = p_nuevo;
  delete from public.pedido_detalle where pedido_id = p_nuevo;
end $$;
revoke all on function public.cancelar_reparto(uuid, uuid) from public, anon;
grant execute on function public.cancelar_reparto(uuid, uuid) to authenticated;

-- Tras cobrar una parte: si en la cuenta original ya no queda nada, se cierra
create or replace function public.cerrar_cuenta_vacia(p_pedido uuid)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
  perform public.cuenta_abierta(p_pedido);
  if exists (select 1 from public.pedido_detalle where pedido_id = p_pedido and estado_cocina <> 'anulado') then
    return false;
  end if;
  update public.pedidos set estado = 'unido' where id = p_pedido;
  return true;
end $$;
revoke all on function public.cerrar_cuenta_vacia(uuid) from public, anon;
grant execute on function public.cerrar_cuenta_vacia(uuid) to authenticated;

-- Directamente (sin pasar por estas funciones) un camarero ya no cambia cantidades, precios ni
-- cuentas de los platos, ni deja una cuenta "unida". Dentro de las funciones de arriba el usuario
-- de la base es el dueño, no 'authenticated', y sí se puede.
create or replace function public.proteger_lineas()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated' and coalesce(public.mi_rol(), '') <> 'admin'
     and (new.cantidad is distinct from old.cantidad or new.precio_unitario is distinct from old.precio_unitario
          or new.pedido_id is distinct from old.pedido_id) then
    raise exception 'Para cambiar platos de cuenta usa Unir o Dividir; para quitar uno, anúlalo';
  end if;
  return new;
end $$;
drop trigger if exists proteger_lineas on public.pedido_detalle;
create trigger proteger_lineas before update on public.pedido_detalle
for each row execute function public.proteger_lineas();

create or replace function public.proteger_estado_pedido()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated' and coalesce(public.mi_rol(), '') <> 'admin'
     and new.estado = 'unido' and old.estado is distinct from 'unido' then
    raise exception 'Para unir cuentas usa la opción Unir';
  end if;
  return new;
end $$;
drop trigger if exists proteger_estado_pedido on public.pedidos;
create trigger proteger_estado_pedido before update on public.pedidos
for each row execute function public.proteger_estado_pedido();
