-- 0016 · Stock / inventario
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.
--
-- articulos_stock  : lo que se compra y se guarda (botella de Coca-Cola, barril, pan, kg de jamón)
-- escandallos      : cuánto gasta cada producto de la carta de cada artículo (Cubata = 0,05 l ginebra + 1 tónica)
-- movimientos_stock: toda subida o bajada. El stock del artículo es la suma de sus movimientos.
--
-- La venta descuenta sola: cuando un pedido pasa a "pagado" (cobro normal o venta sin internet
-- al subirse) se apunta un movimiento "venta" por artículo. Nunca dos veces el mismo pedido.

-- 1 · Tablas ------------------------------------------------------------------------
create table if not exists public.articulos_stock (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  nombre        text not null,
  unidad        text not null default 'ud' check (unidad in ('ud','kg','l')),
  stock         numeric(12,3) not null default 0,
  minimo        numeric(12,3) not null default 0 check (minimo >= 0),
  coste         numeric(12,4) not null default 0 check (coste >= 0),   -- por unidad, IVA no incluido
  proveedor_id  uuid references public.proveedores(id) on delete set null,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now()
);
create index if not exists articulos_stock_empresa_idx on public.articulos_stock (empresa_id);

create table if not exists public.escandallos (
  id           uuid primary key default gen_random_uuid(),
  empresa_id   uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  producto_id  uuid not null references public.productos(id) on delete cascade,
  articulo_id  uuid not null references public.articulos_stock(id) on delete cascade,
  cantidad     numeric(12,3) not null check (cantidad > 0),
  unique (producto_id, articulo_id)
);
create index if not exists escandallos_articulo_idx on public.escandallos (articulo_id);
create index if not exists escandallos_empresa_idx on public.escandallos (empresa_id);

create table if not exists public.movimientos_stock (
  id           uuid primary key default gen_random_uuid(),
  empresa_id   uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  articulo_id  uuid not null references public.articulos_stock(id) on delete cascade,
  tipo         text not null check (tipo in ('venta','anulacion','entrada','merma','recuento')),
  cantidad     numeric(12,3) not null,          -- con signo: + entra, - sale
  coste        numeric(12,4),                   -- precio por unidad en las entradas
  pedido_id    uuid references public.pedidos(id) on delete set null,
  nota         text,
  usuario_id   uuid default auth.uid() references public.perfiles(id) on delete set null,
  creado_en    timestamptz not null default now()
);
create index if not exists movimientos_stock_articulo_idx on public.movimientos_stock (articulo_id, creado_en desc);
create index if not exists movimientos_stock_empresa_idx on public.movimientos_stock (empresa_id, creado_en desc);
-- Un pedido descuenta cada artículo una sola vez (y se anula una sola vez)
create unique index if not exists movimientos_stock_venta_unica
  on public.movimientos_stock (pedido_id, articulo_id, tipo) where pedido_id is not null;

-- 2 · El stock solo cambia con movimientos ---------------------------------------------
create or replace function public.stock_aplicar_movimiento()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.articulos_stock
     set stock = stock + new.cantidad,
         coste = case when new.tipo = 'entrada' and new.coste is not null then new.coste else coste end
   where id = new.articulo_id;
  return new;
end $$;
drop trigger if exists stock_aplicar_movimiento on public.movimientos_stock;
create trigger stock_aplicar_movimiento after insert on public.movimientos_stock
for each row execute function public.stock_aplicar_movimiento();

-- Nadie toca la columna stock a mano (solo el trigger de arriba)
create or replace function public.stock_proteger()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if pg_trigger_depth() < 2 then
    new.stock := old.stock;
  end if;
  return new;
end $$;
drop trigger if exists stock_proteger on public.articulos_stock;
create trigger stock_proteger before update on public.articulos_stock
for each row execute function public.stock_proteger();

-- Un artículo nuevo puede nacer con stock inicial: se convierte en movimiento "recuento"
create or replace function public.stock_inicial()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v numeric := new.stock;
begin
  if v <> 0 then
    update public.articulos_stock set stock = 0 where id = new.id;  -- depth 2: permitido
    insert into public.movimientos_stock (empresa_id, articulo_id, tipo, cantidad, nota)
    values (new.empresa_id, new.id, 'recuento', v, 'Stock inicial');
  end if;
  return null;
end $$;
drop trigger if exists stock_inicial on public.articulos_stock;
create trigger stock_inicial after insert on public.articulos_stock
for each row execute function public.stock_inicial();

-- 3 · Descuento al cobrar --------------------------------------------------------------
create or replace function public.stock_por_pedido()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.estado = 'pagado' and old.estado is distinct from 'pagado' then
    insert into public.movimientos_stock (empresa_id, articulo_id, tipo, cantidad, pedido_id, usuario_id)
    select new.empresa_id, e.articulo_id, 'venta', -sum(d.cantidad * e.cantidad), new.id, new.camarero_id
      from public.pedido_detalle d
      join public.escandallos e on e.producto_id = d.producto_id
     where d.pedido_id = new.id and d.estado_cocina <> 'anulado'
     group by e.articulo_id
    on conflict do nothing;
  elsif old.estado = 'pagado' and new.estado = 'anulado' then
    insert into public.movimientos_stock (empresa_id, articulo_id, tipo, cantidad, pedido_id, nota)
    select new.empresa_id, m.articulo_id, 'anulacion', -m.cantidad, new.id, 'Pedido anulado'
      from public.movimientos_stock m
     where m.pedido_id = new.id and m.tipo = 'venta'
    on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists stock_por_pedido on public.pedidos;
create trigger stock_por_pedido after update of estado on public.pedidos
for each row execute function public.stock_por_pedido();

-- 4 · Seguridad (igual que proveedores/gastos) ---------------------------------------
do $$
declare t text;
begin
  foreach t in array array['articulos_stock','escandallos','movimientos_stock']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "por_empresa" on public.%I', t);
    execute format('create policy "por_empresa" on public.%I as restrictive for all to authenticated
                    using (empresa_id = (select public.empresa_actual()))
                    with check (empresa_id = (select public.empresa_actual()))', t);
    execute format('drop policy if exists "leer_%1$s" on public.%1$I', t);
    execute format('create policy "leer_%1$s" on public.%1$I for select to authenticated
                    using ((select public.mi_rol()) in (''admin'',''camarero''))', t);
    execute format('drop policy if exists "escribir_%1$s" on public.%1$I', t);
    execute format('create policy "escribir_%1$s" on public.%1$I for insert to authenticated
                    with check ((select public.mi_rol()) in (''admin'',''camarero''))', t);
  end loop;
end $$;

-- Artículos y escandallos se editan; los movimientos no se editan ni se borran nunca
drop policy if exists "editar_articulos_stock" on public.articulos_stock;
create policy "editar_articulos_stock" on public.articulos_stock for update to authenticated
  using ((select public.mi_rol()) in ('admin','camarero'))
  with check ((select public.mi_rol()) in ('admin','camarero'));
drop policy if exists "borrar_articulos_stock" on public.articulos_stock;
create policy "borrar_articulos_stock" on public.articulos_stock for delete to authenticated
  using ((select public.mi_rol()) = 'admin');
drop policy if exists "editar_escandallos" on public.escandallos;
create policy "editar_escandallos" on public.escandallos for update to authenticated
  using ((select public.mi_rol()) in ('admin','camarero'))
  with check ((select public.mi_rol()) in ('admin','camarero'));
drop policy if exists "borrar_escandallos" on public.escandallos;
create policy "borrar_escandallos" on public.escandallos for delete to authenticated
  using ((select public.mi_rol()) in ('admin','camarero'));
