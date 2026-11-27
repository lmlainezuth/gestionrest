-- 0040 · Cada referencia apunta a un registro del MISMO bar (auditoría 27/11/2026).
-- La política por_empresa solo mira el empresa_id de la fila que se escribe. Las claves foráneas
-- (pedido_id, articulo_id, producto_id, grupo_id, factura_id...) se comprueban sin RLS, así que una
-- línea del bar A podía apuntar a un pedido del bar B, y los triggers de servidor (recalcular_pedido,
-- stock_aplicar_movimiento, stock_por_pedido, auditar_factura_anulada) cambiaban o leían datos de B.
-- 1) Un trigger comprueba en cada escritura que el registro referido es del mismo bar.
-- 2) Esas funciones de servidor filtran además por bar (por si queda algún dato antiguo cruzado).
-- 3) pedido_detalle_modificadores pasa a tener empresa_id y su política por_empresa.
-- 4) La carta pública solo lista productos del propio bar.
-- No toca datos existentes. Al final hay una consulta para ver si ya hay filas cruzadas.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Comprobación genérica: pares (columna, tabla referida) en los argumentos del trigger
-- =====================================================================
create or replace function public.misma_empresa()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  i int := 0;
  v_col text;
  v_tabla text;
  v_id uuid;
  v_empresa uuid;
begin
  while i < tg_nargs loop
    v_col := tg_argv[i];
    v_tabla := tg_argv[i + 1];
    i := i + 2;
    v_id := (to_jsonb(new) ->> v_col)::uuid;
    continue when v_id is null;
    execute format('select empresa_id from public.%I where id = $1', v_tabla) into v_empresa using v_id;
    -- Si no existe, la clave foránea dará su propio error
    if v_empresa is not null and v_empresa is distinct from new.empresa_id then
      raise exception 'No se puede enlazar con un registro de otro bar (%.%)', tg_table_name, v_col
        using errcode = '42501';
    end if;
  end loop;
  return new;
end $$;
revoke all on function public.misma_empresa() from public, anon, authenticated;

-- =====================================================================
-- 2 · pedido_detalle_modificadores: empresa_id como el resto de tablas del bar
-- =====================================================================
alter table public.pedido_detalle_modificadores add column if not exists empresa_id uuid references public.empresa(id) on delete cascade;
update public.pedido_detalle_modificadores m set empresa_id = d.empresa_id
  from public.pedido_detalle d where d.id = m.detalle_id and m.empresa_id is null;
alter table public.pedido_detalle_modificadores alter column empresa_id set default public.empresa_actual();
alter table public.pedido_detalle_modificadores alter column empresa_id set not null;
create index if not exists pedido_detalle_modificadores_empresa_idx on public.pedido_detalle_modificadores (empresa_id);
drop policy if exists "por_empresa" on public.pedido_detalle_modificadores;
create policy "por_empresa" on public.pedido_detalle_modificadores as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()))
  with check (empresa_id = (select public.empresa_actual()));

-- =====================================================================
-- 3 · Los triggers (nombre "aa_" para que corran antes que los demás BEFORE)
-- =====================================================================
do $$
declare
  r record;
begin
  for r in select * from (values
    ('mesas',                        'insert or update', 'salon_id,salones'),
    ('productos',                    'insert or update', 'grupo_id,grupos_productos,area_id,areas_preparacion'),
    ('producto_modificadores',       'insert or update', 'producto_id,productos,modificador_id,modificadores'),
    ('turnos_caja',                  'insert or update', 'caja_id,cajas'),
    ('movimientos_caja',             'insert or update', 'turno_id,turnos_caja,concepto_id,conceptos_gasto'),
    ('pedidos',                      'insert or update', 'mesa_id,mesas,cliente_id,clientes,turno_id,turnos_caja'),
    ('pedido_detalle',               'insert or update', 'pedido_id,pedidos,producto_id,productos,area_id,areas_preparacion'),
    ('pedido_detalle_modificadores', 'insert or update', 'detalle_id,pedido_detalle,modificador_id,modificadores'),
    ('pagos',                        'insert or update', 'pedido_id,pedidos,turno_id,turnos_caja'),
    ('facturas',                     'insert',           'pedido_id,pedidos,caja_id,cajas,rectifica_id,facturas,anterior_id,facturas'),
    ('tbai_anulaciones',             'insert or update', 'factura_id,facturas'),
    ('tbai_subsanaciones',           'insert or update', 'factura_id,facturas'),
    ('gastos',                       'insert or update', 'proveedor_id,proveedores'),
    ('articulos_stock',              'insert or update', 'proveedor_id,proveedores'),
    ('escandallos',                  'insert or update', 'producto_id,productos,articulo_id,articulos_stock'),
    ('movimientos_stock',            'insert',           'articulo_id,articulos_stock,pedido_id,pedidos'),
    ('fichajes',                     'insert',           'corrige_id,fichajes'),
    ('pedidos_proveedor',            'insert or update', 'proveedor_id,proveedores,gasto_id,gastos'),
    ('pedido_proveedor_lineas',      'insert or update', 'pedido_id,pedidos_proveedor,articulo_id,articulos_stock'),
    ('reservas',                     'insert or update', 'mesa_id,mesas')
  ) as t(tabla, cuando, args)
  loop
    execute format('drop trigger if exists aa_misma_empresa on public.%I', r.tabla);
    execute format('create trigger aa_misma_empresa before %s on public.%I for each row execute function public.misma_empresa(%s)',
                   r.cuando, r.tabla,
                   (select string_agg(quote_literal(a), ',') from unnest(string_to_array(r.args, ',')) a));
  end loop;
end $$;

-- =====================================================================
-- 4 · Las funciones de servidor filtran por bar
-- =====================================================================
create or replace function public.recalcular_pedido()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pedido uuid := coalesce(new.pedido_id, old.pedido_id);
  v_empresa uuid;
  v_sub numeric(12,2);
  v_pct numeric(5,2);
  v_con boolean;
begin
  select p.empresa_id, e.impuesto_porcentaje, e.trabaja_con_impuestos
    into v_empresa, v_pct, v_con
    from public.pedidos p join public.empresa e on e.id = p.empresa_id
   where p.id = v_pedido;

  select coalesce(sum(d.cantidad * (d.precio_unitario +
           coalesce((select sum(m.precio) from public.pedido_detalle_modificadores m
                     where m.detalle_id = d.id and m.empresa_id = v_empresa), 0))), 0)
    into v_sub
    from public.pedido_detalle d
   where d.pedido_id = v_pedido and d.empresa_id = v_empresa and d.estado_cocina <> 'anulado';

  update public.pedidos set
    total    = v_sub,
    impuesto = case when coalesce(v_con,false) then round(v_sub - v_sub / (1 + v_pct/100), 2) else 0 end,
    subtotal = case when coalesce(v_con,false) then round(v_sub / (1 + v_pct/100), 2) else v_sub end
  where id = v_pedido;
  return null;
end $$;

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
   where id = new.articulo_id and empresa_id = new.empresa_id;
  return new;
end $$;

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
      join public.escandallos e on e.producto_id = d.producto_id and e.empresa_id = new.empresa_id
     where d.pedido_id = new.id and d.empresa_id = new.empresa_id and d.estado_cocina <> 'anulado'
     group by e.articulo_id
    on conflict do nothing;
  elsif old.estado = 'pagado' and new.estado = 'anulado' then
    insert into public.movimientos_stock (empresa_id, articulo_id, tipo, cantidad, pedido_id, nota)
    select new.empresa_id, m.articulo_id, 'anulacion', -m.cantidad, new.id, 'Pedido anulado'
      from public.movimientos_stock m
     where m.pedido_id = new.id and m.empresa_id = new.empresa_id and m.tipo = 'venta'
    on conflict do nothing;
  end if;
  return new;
end $$;

create or replace function public.auditar_factura_anulada()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.registro_anulaciones (empresa_id, momento, usuario_id, tipo, descripcion, importe, pedido_id, mesa, motivo)
  select new.empresa_id, new.fecha, coalesce(new.creado_por, auth.uid()), 'factura_anulada',
         'Factura ' || f.serie || '-' || f.numero, f.importe_total, f.pedido_id,
         public.mesa_de_pedido(f.pedido_id), new.motivo
    from public.facturas f where f.id = new.factura_id and f.empresa_id = new.empresa_id;
  return new;
end $$;

-- La carta pública: solo productos del propio bar
create or replace function public.carta_publica(p_codigo uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'nombre', e.nombre,
    'grupos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nombre', g.nombre,
               'color', g.color,
               'productos', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'nombre', p.nombre, 'precio', p.precio_venta,
                          'alergenos', p.alergenos, 'imagen', p.imagen_url) order by p.nombre), '[]'::jsonb)
                   from public.productos p
                  where p.grupo_id = g.id and p.empresa_id = e.id and p.activo))
             order by g.orden, g.nombre)
        from public.grupos_productos g
       where g.empresa_id = e.id and g.activo
         and exists (select 1 from public.productos p where p.grupo_id = g.id and p.empresa_id = e.id and p.activo)
    ), '[]'::jsonb))
  from public.empresa e where e.codigo_carta = p_codigo
$$;
revoke all on function public.carta_publica(uuid) from public;
grant execute on function public.carta_publica(uuid) to anon, authenticated;

-- =====================================================================
-- 5 · ¿Hay ya filas cruzadas? (solo lectura; debería salir todo a 0)
-- =====================================================================
-- select 'pedido_detalle' t, count(*) from public.pedido_detalle d join public.pedidos p on p.id = d.pedido_id where d.empresa_id <> p.empresa_id
-- union all select 'movimientos_stock', count(*) from public.movimientos_stock m join public.articulos_stock a on a.id = m.articulo_id where m.empresa_id <> a.empresa_id
-- union all select 'escandallos', count(*) from public.escandallos e join public.productos p on p.id = e.producto_id where e.empresa_id <> p.empresa_id
-- union all select 'productos', count(*) from public.productos p join public.grupos_productos g on g.id = p.grupo_id where p.empresa_id <> g.empresa_id
-- union all select 'tbai_anulaciones', count(*) from public.tbai_anulaciones a join public.facturas f on f.id = a.factura_id where a.empresa_id <> f.empresa_id
-- union all select 'facturas.anterior_id', count(*) from public.facturas f join public.facturas p on p.id = f.anterior_id where f.empresa_id <> p.empresa_id;
