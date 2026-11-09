-- 0020 · Pedidos a proveedor, reservas, carta QR pública y correo del resumen diario
-- Ejecutar entero en el SQL Editor (después de 0016 y 0019). Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Pedidos a proveedor
-- =====================================================================
create table if not exists public.pedidos_proveedor (
  id            uuid primary key default gen_random_uuid(),
  numero        bigint generated always as identity,
  empresa_id    uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  proveedor_id  uuid references public.proveedores(id) on delete set null,
  estado        text not null default 'pendiente' check (estado in ('pendiente','recibido','cancelado')),
  nota          text,
  albaran       text,
  gasto_id      uuid references public.gastos(id) on delete set null,
  creado_por    uuid default auth.uid() references public.perfiles(id) on delete set null,
  creado_en     timestamptz not null default now(),
  recibido_en   timestamptz
);
create table if not exists public.pedido_proveedor_lineas (
  id           uuid primary key default gen_random_uuid(),
  empresa_id   uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  pedido_id    uuid not null references public.pedidos_proveedor(id) on delete cascade,
  articulo_id  uuid not null references public.articulos_stock(id) on delete cascade,
  pedida       numeric(12,3) not null check (pedida > 0),
  recibida     numeric(12,3),
  coste        numeric(12,4)          -- por unidad, sin IVA
);
create index if not exists pedidos_proveedor_idx on public.pedidos_proveedor (empresa_id, creado_en desc);
create index if not exists pedido_proveedor_lineas_idx on public.pedido_proveedor_lineas (pedido_id);

-- Recibir: actualiza las líneas, mete en stock lo que llegó y apunta el gasto. Todo o nada.
create or replace function public.recibir_pedido_proveedor(p_pedido uuid, p_lineas jsonb, p_importe numeric,
                                                          p_pagado boolean default false, p_albaran text default null)
returns uuid   -- gasto creado (o null si importe 0)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v public.pedidos_proveedor;
  l jsonb;
  v_gasto uuid;
  v_iva text;
begin
  select * into v from public.pedidos_proveedor where id = p_pedido for update;
  if v.id is null then raise exception 'Pedido no encontrado'; end if;
  if v.estado <> 'pendiente' then raise exception 'Este pedido ya está %', v.estado; end if;

  for l in select * from jsonb_array_elements(p_lineas) loop
    update public.pedido_proveedor_lineas
       set recibida = (l->>'recibida')::numeric,
           coste = nullif(l->>'coste', '')::numeric
     where id = (l->>'id')::uuid and pedido_id = p_pedido;
  end loop;

  insert into public.movimientos_stock (articulo_id, tipo, cantidad, coste, nota)
  select pl.articulo_id, 'entrada', pl.recibida, pl.coste,
         'Pedido nº ' || v.numero || coalesce(' · albarán ' || nullif(trim(p_albaran), ''), '')
    from public.pedido_proveedor_lineas pl
   where pl.pedido_id = p_pedido and coalesce(pl.recibida, 0) > 0;

  if coalesce(p_importe, 0) > 0 then
    select coalesce(pr.iva_habitual, '10') into v_iva from public.proveedores pr where pr.id = v.proveedor_id;
    insert into public.gastos (proveedor_id, fecha, concepto, importe, categoria, iva_tipo, estado)
    values (v.proveedor_id, (now() at time zone 'Europe/Madrid')::date,
            coalesce('Albarán ' || nullif(trim(p_albaran), ''), 'Pedido nº ' || v.numero),
            p_importe, 'materia', coalesce(v_iva, '10'),
            case when p_pagado then 'registrado' else 'pendiente' end)
    returning id into v_gasto;
  end if;

  update public.pedidos_proveedor
     set estado = 'recibido', recibido_en = now(), gasto_id = v_gasto, albaran = nullif(trim(p_albaran), '')
   where id = p_pedido;
  return v_gasto;
end $$;
grant execute on function public.recibir_pedido_proveedor(uuid, jsonb, numeric, boolean, text) to authenticated;

-- =====================================================================
-- 2 · Reservas
-- =====================================================================
create table if not exists public.reservas (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  fecha       date not null,
  hora        time not null,
  nombre      text not null,
  telefono    text,
  personas    int not null default 2 check (personas > 0),
  mesa_id     uuid references public.mesas(id) on delete set null,
  nota        text,
  estado      text not null default 'confirmada' check (estado in ('confirmada','sentada','no_vino','cancelada')),
  creado_por  uuid default auth.uid() references public.perfiles(id) on delete set null,
  creado_en   timestamptz not null default now()
);
create index if not exists reservas_idx on public.reservas (empresa_id, fecha, hora);

-- =====================================================================
-- 3 · Seguridad de las tablas nuevas (como proveedores/gastos)
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array['pedidos_proveedor','pedido_proveedor_lineas','reservas']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "por_empresa" on public.%I', t);
    execute format('create policy "por_empresa" on public.%I as restrictive for all to authenticated
                    using (empresa_id = (select public.empresa_actual()))
                    with check (empresa_id = (select public.empresa_actual()))', t);
    execute format('drop policy if exists "usar_%1$s" on public.%1$I', t);
    execute format('create policy "usar_%1$s" on public.%1$I for all to authenticated
                    using ((select public.mi_rol()) in (''admin'',''camarero''))
                    with check ((select public.mi_rol()) in (''admin'',''camarero''))', t);
  end loop;
end $$;

-- =====================================================================
-- 4 · Carta pública (QR): solo lectura, sin iniciar sesión, solo lo activo
-- =====================================================================
create or replace function public.carta_publica(p_empresa uuid)
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
                  where p.grupo_id = g.id and p.activo))
             order by g.orden, g.nombre)
        from public.grupos_productos g
       where g.empresa_id = e.id and g.activo
         and exists (select 1 from public.productos p where p.grupo_id = g.id and p.activo)
    ), '[]'::jsonb))
  from public.empresa e where e.id = p_empresa
$$;
grant execute on function public.carta_publica(uuid) to anon, authenticated;

-- =====================================================================
-- 5 · Resumen diario: a qué correo se manda (por empresa)
-- =====================================================================
alter table public.empresa add column if not exists correo_resumen text;

-- Programar el resumen todos los días a las 06:30 (Madrid, invierno) — mismas claves que la copia:
-- select cron.schedule('resumen-diario', '30 5 * * *', $cron$
--   select net.http_post(
--     url := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/resumen-diario',
--     headers := jsonb_build_object('Content-Type', 'application/json',
--                                   'Authorization', 'Bearer TU_CLAVE_ANON',
--                                   'x-copia-secreto', 'TU_SECRETO'),
--     body := '{}'::jsonb,
--     timeout_milliseconds := 60000)
-- $cron$);
