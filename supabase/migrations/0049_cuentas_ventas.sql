-- 0049 · Cuentas y ventas sin trampas (informe de seguridad run-2, pistas 2, 3 y 10).
--  · cancelar_reparto solo deshace un reparto de verdad: la cuenta nueva tiene que haber salido
--    de la original con repartir_cuenta (pedidos.reparto_de) y no pueden ser la misma.
--    pedido_detalle.reparto_de y pedidos.reparto_de solo los escriben las funciones del servidor.
--  · Un pedido pasa a «pagado» solo si sus cobros suman el total. El total no se escribe a mano
--    (lo calcula la base con las líneas). Un pedido pagado ya no se reabre desde la app.
--  · El precio de cada línea lo pone la base: precio del producto más sus extras (la app manda
--    qué extras lleva en pedido_detalle.modificadores). Nunca negativo. Las líneas de ventas hechas
--    sin internet (sin_conexion = true) ya van firmadas a Hacienda: se respeta su precio, pero si no
--    coincide con el de ahora queda apuntado en Seguridad.
--  · pedido_detalle_modificadores (la app no la usa) solo la escribe el administrador.
--  · Al abrir turno, la base compara el fondo con lo que se dejó al cerrar el anterior de esa
--    caja. Si no coincide lo anota en el turno y en eventos_seguridad.
-- ORDEN: la app nueva en todos los equipos ANTES de esta migración (la antigua no manda los
-- extras y se cobrarían a precio base). Ejecutar entero en el SQL Editor. Se puede ejecutar más
-- de una vez.

-- =====================================================================
-- 1 · Columnas nuevas
-- =====================================================================
alter table public.pedidos add column if not exists reparto_de uuid references public.pedidos(id) on delete set null;
alter table public.pedido_detalle add column if not exists modificadores uuid[];
alter table public.pedido_detalle add column if not exists sin_conexion boolean not null default false;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pedido_detalle_precio_no_negativo') then
    alter table public.pedido_detalle add constraint pedido_detalle_precio_no_negativo
      check (precio_unitario >= 0) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'pedido_detalle_modificadores_precio_no_negativo') then
    alter table public.pedido_detalle_modificadores add constraint pedido_detalle_modificadores_precio_no_negativo
      check (precio >= 0) not valid;
  end if;
end $$;

-- Las referencias nuevas, también del mismo bar (como la 0040)
drop trigger if exists aa_misma_empresa on public.pedido_detalle;
create trigger aa_misma_empresa before insert or update on public.pedido_detalle
for each row execute function public.misma_empresa('pedido_id', 'pedidos', 'producto_id', 'productos',
                                                   'area_id', 'areas_preparacion', 'reparto_de', 'pedido_detalle');
drop trigger if exists aa_misma_empresa on public.pedidos;
create trigger aa_misma_empresa before insert or update on public.pedidos
for each row execute function public.misma_empresa('mesa_id', 'mesas', 'cliente_id', 'clientes',
                                                   'turno_id', 'turnos_caja', 'reparto_de', 'pedidos');

-- =====================================================================
-- 2 · Repartir y cancelar el reparto
-- =====================================================================
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
  -- Las copias de las líneas conservan su precio (precio_de_linea no las recalcula)
  perform set_config('gestionrest.servidor', '1', true);
  insert into public.pedidos (empresa_id, tipo, mesa_id, nombre_llevar, camarero_id, num_personas, reparto_de)
  values (v_ped.empresa_id, v_ped.tipo, v_ped.mesa_id, v_ped.nombre_llevar, auth.uid(), 1, p_pedido)
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
         nota, curso, estado_cocina, en_espera, reparto_de, modificadores, sin_conexion)
      values (v_lin.empresa_id, v_nuevo, v_lin.producto_id, v_lin.area_id, v_lin.descripcion, v_k,
              v_lin.precio_unitario, v_lin.tipo_iva, v_lin.nota, v_lin.curso, v_lin.estado_cocina,
              v_lin.en_espera, v_lin.id, v_lin.modificadores, v_lin.sin_conexion);
    end if;
  end loop;
  if not exists (select 1 from public.pedido_detalle where pedido_id = v_nuevo) then
    raise exception 'Elige lo que paga esta persona';
  end if;
  return v_nuevo;
end $$;
revoke all on function public.repartir_cuenta(uuid, jsonb) from public, anon;
grant execute on function public.repartir_cuenta(uuid, jsonb) to authenticated;

create or replace function public.cancelar_reparto(p_nuevo uuid, p_original uuid)
returns void
language plpgsql security definer
set search_path = ''
as $$
declare
  v_lin public.pedido_detalle;
  v_nuevo public.pedidos;
begin
  if p_nuevo = p_original then raise exception 'Elige la cuenta del reparto'; end if;
  perform public.cuenta_abierta(p_original);
  v_nuevo := public.cuenta_abierta(p_nuevo);
  -- Solo una cuenta que salió de la original con «Dividir» (los repartos hechos antes de esta
  -- versión no lo tienen apuntado: se juntan con «Unir»)
  if v_nuevo.reparto_de is distinct from p_original then
    raise exception 'Esa cuenta no es un reparto de esta: júntalas con Unir';
  end if;
  for v_lin in select * from public.pedido_detalle where pedido_id = p_nuevo for update loop
    if v_lin.reparto_de is not null
       and exists (select 1 from public.pedido_detalle o
                    where o.id = v_lin.reparto_de and o.pedido_id = p_original
                      and o.producto_id is not distinct from v_lin.producto_id
                      and o.precio_unitario = v_lin.precio_unitario
                      and o.estado_cocina <> 'anulado') then
      update public.pedido_detalle set cantidad = cantidad + v_lin.cantidad where id = v_lin.reparto_de;
    else
      update public.pedido_detalle set pedido_id = p_original, reparto_de = null where id = v_lin.id;
    end if;
  end loop;
  -- Primero "unida" y luego se borran las copias ya sumadas: no es una anulación
  update public.pedidos set estado = 'unido' where id = p_nuevo;
  delete from public.pedido_detalle where pedido_id = p_nuevo;
end $$;
revoke all on function public.cancelar_reparto(uuid, uuid) from public, anon;
grant execute on function public.cancelar_reparto(uuid, uuid) to authenticated;

-- =====================================================================
-- 3 · Líneas: reparto_de y precio los pone el servidor
-- =====================================================================
create or replace function public.proteger_lineas()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user = 'authenticated' then
    if new.reparto_de is distinct from old.reparto_de then
      raise exception 'Para dividir una cuenta usa Dividir';
    end if;
    if new.modificadores is distinct from old.modificadores or new.sin_conexion is distinct from old.sin_conexion then
      raise exception 'Los extras de un plato no se cambian: anúlalo y añádelo de nuevo';
    end if;
    if coalesce(public.mi_rol(), '') <> 'admin'
       and (new.cantidad is distinct from old.cantidad or new.precio_unitario is distinct from old.precio_unitario
            or new.pedido_id is distinct from old.pedido_id) then
      raise exception 'Para cambiar platos de cuenta usa Unir o Dividir; para quitar uno, anúlalo';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists proteger_lineas on public.pedido_detalle;
create trigger proteger_lineas before update on public.pedido_detalle
for each row execute function public.proteger_lineas();

-- Al añadir una línea desde la app: precio = producto + extras de ese producto (del mismo bar)
create or replace function public.precio_de_linea()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base numeric;
  v_extras numeric;
  v_precio numeric;
begin
  -- Es security definer (apunta en eventos_seguridad): current_user aquí es siempre el dueño, así
  -- que el servidor se reconoce por el rol de la sesión (service_role, SQL Editor) o por la marca
  -- que pone repartir_cuenta, que copia la línea tal cual. La app no puede poner esa marca.
  if coalesce(auth.role(), '') <> 'authenticated' or current_setting('gestionrest.servidor', true) = '1' then
    return new;
  end if;
  if new.reparto_de is not null then
    raise exception 'Para dividir una cuenta usa Dividir';
  end if;
  if new.producto_id is null then
    if coalesce(public.mi_rol(), '') <> 'admin' and not new.sin_conexion then
      raise exception 'Cada plato tiene que ser un producto de la carta';
    end if;
    return new;
  end if;
  select p.precio_venta into v_base from public.productos p
   where p.id = new.producto_id and p.empresa_id = new.empresa_id;
  select coalesce(sum(m.precio), 0) into v_extras
    from public.modificadores m
    join public.producto_modificadores pm on pm.modificador_id = m.id and pm.producto_id = new.producto_id
   where m.id = any (coalesce(new.modificadores, '{}'::uuid[])) and m.empresa_id = new.empresa_id;
  v_precio := round(coalesce(v_base, 0) + v_extras, 2);
  if new.sin_conexion then
    -- Venta sin internet ya firmada: se respeta, pero si el precio no cuadra queda apuntado
    if new.precio_unitario is distinct from v_precio then
      insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
      values (new.empresa_id, 'precio_distinto', auth.uid(),
              left(format('%s: %s € en la venta sin internet; ahora vale %s €', new.descripcion,
                          new.precio_unitario, v_precio), 500));
    end if;
  else
    new.precio_unitario := v_precio;
  end if;
  return new;
end $$;
revoke all on function public.precio_de_linea() from public, anon, authenticated;
drop trigger if exists precio_de_linea on public.pedido_detalle;
create trigger precio_de_linea before insert on public.pedido_detalle
for each row execute function public.precio_de_linea();

-- Los extras sueltos (tabla que la app no usa) solo los toca el administrador
drop policy if exists "escribir_det_mod" on public.pedido_detalle_modificadores;
create policy "escribir_det_mod" on public.pedido_detalle_modificadores for all to authenticated
  using ((select public.mi_rol()) = 'admin')
  with check ((select public.mi_rol()) = 'admin');

-- =====================================================================
-- 4 · Pedidos: total calculado y «pagado» solo con los cobros
-- =====================================================================
-- ¿Los cobros del pedido cubren su total? Solo sí o no: el camarero no lee los cobros (cuadre ciego)
create or replace function public.pagos_cubren(p_pedido uuid, p_total numeric)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select coalesce(sum(pg.importe), 0) >= p_total - 0.005
    from public.pagos pg
    join public.pedidos p on p.id = pg.pedido_id
   where pg.pedido_id = p_pedido and p.empresa_id = (select public.empresa_actual())
$$;
revoke all on function public.pagos_cubren(uuid, numeric) from public, anon;
grant execute on function public.pagos_cubren(uuid, numeric) to authenticated;

create or replace function public.proteger_estado_pedido()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;   -- recalcular_pedido y las funciones del servidor
  end if;
  if tg_op = 'INSERT' then
    new.total := 0;
    new.subtotal := 0;
    new.impuesto := 0;
    new.reparto_de := null;
    if new.estado not in ('abierto', 'precuenta') then
      raise exception 'Un pedido nuevo empieza abierto';
    end if;
    return new;
  end if;
  if new.total is distinct from old.total or new.subtotal is distinct from old.subtotal
     or new.impuesto is distinct from old.impuesto then
    raise exception 'El total de la cuenta lo calculan sus platos';
  end if;
  if new.reparto_de is distinct from old.reparto_de then
    raise exception 'Para dividir una cuenta usa Dividir';
  end if;
  if new.estado = 'unido' and old.estado is distinct from 'unido'
     and coalesce(public.mi_rol(), '') <> 'admin' then
    raise exception 'Para unir cuentas usa la opción Unir';
  end if;
  if new.estado = 'pagado' and old.estado is distinct from 'pagado'
     and not public.pagos_cubren(new.id, new.total) then
    raise exception 'Faltan cobros: lo cobrado no llega al total de la cuenta (% €)', new.total;
  end if;
  if old.estado in ('pagado', 'anulado', 'unido') and new.estado is distinct from old.estado
     and coalesce(public.mi_rol(), '') <> 'admin' then
    raise exception 'Esta cuenta ya está cerrada';
  end if;
  return new;
end $$;
drop trigger if exists proteger_estado_pedido on public.pedidos;
create trigger proteger_estado_pedido before insert or update on public.pedidos
for each row execute function public.proteger_estado_pedido();

-- =====================================================================
-- 5 · Fondo al abrir turno, comparado en el servidor
-- =====================================================================
create or replace function public.fondo_al_abrir()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dejado numeric;
begin
  select t.fondo_siguiente into v_dejado
    from public.turnos_caja t
   where t.caja_id = new.caja_id and t.empresa_id = new.empresa_id and t.estado = 'cerrado'
   order by t.cerrado_en desc nulls last, t.abierto_en desc
   limit 1;
  if v_dejado is not null and abs(coalesce(new.efectivo_inicial, 0) - v_dejado) >= 0.005 then
    new.nota := left(concat_ws(' · ', nullif(new.nota, ''),
                     format('Abrió con %s €; al cerrar se dejaron %s €', new.efectivo_inicial, v_dejado)), 500);
    insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
    values (new.empresa_id, 'fondo_distinto', auth.uid(),
            format('Abrió con %s €; al cerrar se dejaron %s €', new.efectivo_inicial, v_dejado));
  end if;
  return new;
end $$;
revoke all on function public.fondo_al_abrir() from public, anon, authenticated;
drop trigger if exists fondo_al_abrir on public.turnos_caja;
create trigger fondo_al_abrir before insert on public.turnos_caja
for each row execute function public.fondo_al_abrir();
