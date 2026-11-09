-- 0019 · Control de anulaciones + registro de copias de seguridad
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Registro de anulaciones: lo apunta la base de datos sola (no se puede saltar desde la app)
-- =====================================================================
create table if not exists public.registro_anulaciones (
  id           uuid primary key default gen_random_uuid(),
  empresa_id   uuid not null references public.empresa(id) on delete cascade,
  momento      timestamptz not null default now(),
  usuario_id   uuid references public.perfiles(id) on delete set null,
  tipo         text not null check (tipo in ('linea_anulada','linea_borrada','pedido_anulado','venta_anulada',
                                             'factura_anulada','devolucion')),
  descripcion  text,
  cantidad     numeric(10,2),
  importe      numeric(12,2) not null default 0,
  pedido_id    uuid,
  mesa         text,
  motivo       text,
  estado_cocina text          -- en qué punto estaba el plato al anularlo
);
create index if not exists registro_anulaciones_idx on public.registro_anulaciones (empresa_id, momento desc);

alter table public.registro_anulaciones enable row level security;
drop policy if exists "por_empresa" on public.registro_anulaciones;
create policy "por_empresa" on public.registro_anulaciones as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()));
drop policy if exists "admin_ver_anulaciones" on public.registro_anulaciones;
create policy "admin_ver_anulaciones" on public.registro_anulaciones for select to authenticated
  using ((select public.mi_rol()) = 'admin');
-- Sin políticas de escritura: solo escriben los triggers

create or replace function public.mesa_de_pedido(p_pedido uuid)
returns text
language sql stable security definer
set search_path = ''
as $$
  select coalesce(m.nombre, case when p.tipo = 'barra' then 'Barra' || coalesce(' · ' || p.nombre_llevar, '')
                                 else 'Para llevar' || coalesce(' · ' || p.nombre_llevar, '') end)
    from public.pedidos p left join public.mesas m on m.id = p.mesa_id
   where p.id = p_pedido
$$;

-- Línea anulada (ya enviada a cocina/barra)
create or replace function public.auditar_linea_anulada()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.estado_cocina = 'anulado' and old.estado_cocina is distinct from 'anulado' then
    insert into public.registro_anulaciones
      (empresa_id, usuario_id, tipo, descripcion, cantidad, importe, pedido_id, mesa, motivo, estado_cocina)
    values (new.empresa_id, auth.uid(), 'linea_anulada', new.descripcion, new.cantidad,
            new.cantidad * new.precio_unitario, new.pedido_id, public.mesa_de_pedido(new.pedido_id),
            new.anulado_motivo, old.estado_cocina);
  end if;
  return new;
end $$;
drop trigger if exists auditar_linea_anulada on public.pedido_detalle;
create trigger auditar_linea_anulada after update of estado_cocina on public.pedido_detalle
for each row execute function public.auditar_linea_anulada();

-- Línea borrada (no debería pasar en uso normal: se anula, no se borra)
create or replace function public.auditar_linea_borrada()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_estado text;
begin
  select estado into v_estado from public.pedidos where id = old.pedido_id;
  -- Repartos de cuenta cancelados (pedido ya anulado/unido) y líneas ya anuladas no cuentan
  if old.estado_cocina = 'anulado' or v_estado in ('anulado','unido') then
    return old;
  end if;
  insert into public.registro_anulaciones
    (empresa_id, usuario_id, tipo, descripcion, cantidad, importe, pedido_id, mesa, motivo, estado_cocina)
  values (old.empresa_id, auth.uid(), 'linea_borrada', old.descripcion, old.cantidad,
          old.cantidad * old.precio_unitario, old.pedido_id,
          coalesce(public.mesa_de_pedido(old.pedido_id), 'Pedido borrado'),
          case when v_estado is null then 'Se borró el pedido entero' end, old.estado_cocina);
  return old;
end $$;
drop trigger if exists auditar_linea_borrada on public.pedido_detalle;
create trigger auditar_linea_borrada after delete on public.pedido_detalle
for each row execute function public.auditar_linea_borrada();

-- Pedido anulado (abierto con consumiciones, o ya cobrado)
create or replace function public.auditar_pedido_anulado()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare v_importe numeric;
begin
  if new.estado = 'anulado' and old.estado is distinct from 'anulado' then
    select coalesce(sum(d.cantidad * d.precio_unitario), 0) into v_importe
      from public.pedido_detalle d where d.pedido_id = new.id and d.estado_cocina <> 'anulado';
    if v_importe > 0 or old.estado = 'pagado' then
      insert into public.registro_anulaciones (empresa_id, usuario_id, tipo, descripcion, importe, pedido_id, mesa, motivo)
      values (new.empresa_id, auth.uid(), case when old.estado = 'pagado' then 'venta_anulada' else 'pedido_anulado' end,
              'Pedido nº ' || new.numero, greatest(v_importe, new.total), new.id,
              public.mesa_de_pedido(new.id), new.nota);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists auditar_pedido_anulado on public.pedidos;
create trigger auditar_pedido_anulado after update of estado on public.pedidos
for each row execute function public.auditar_pedido_anulado();

-- Factura anulada en TicketBAI
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
    from public.facturas f where f.id = new.factura_id;
  return new;
end $$;
drop trigger if exists auditar_factura_anulada on public.tbai_anulaciones;
create trigger auditar_factura_anulada after insert on public.tbai_anulaciones
for each row execute function public.auditar_factura_anulada();

-- Devolución (factura rectificativa)
create or replace function public.auditar_devolucion()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.tipo = 'rectificativa' then
    insert into public.registro_anulaciones (empresa_id, momento, usuario_id, tipo, descripcion, importe, pedido_id, mesa)
    values (new.empresa_id, new.creado_en, coalesce(new.creado_por, auth.uid()), 'devolucion',
            'Rectificativa ' || new.serie || '-' || new.numero, abs(new.importe_total), new.pedido_id,
            public.mesa_de_pedido(new.pedido_id));
  end if;
  return new;
end $$;
drop trigger if exists auditar_devolucion on public.facturas;
create trigger auditar_devolucion after insert on public.facturas
for each row execute function public.auditar_devolucion();

-- =====================================================================
-- 2 · Copias de seguridad en Google Drive (las hace la función copia-mensual)
-- =====================================================================
create table if not exists public.copias_seguridad (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresa(id) on delete cascade,
  mes         text not null,                     -- '2026-10'
  creado_en   timestamptz not null default now(),
  estado      text not null check (estado in ('ok','error')),
  archivo     text,
  enlace      text,
  bytes       bigint,
  detalle     text
);
create index if not exists copias_seguridad_idx on public.copias_seguridad (empresa_id, creado_en desc);
alter table public.copias_seguridad enable row level security;
drop policy if exists "por_empresa" on public.copias_seguridad;
create policy "por_empresa" on public.copias_seguridad as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()));
drop policy if exists "admin_ver_copias" on public.copias_seguridad;
create policy "admin_ver_copias" on public.copias_seguridad for select to authenticated
  using ((select public.mi_rol()) = 'admin');

-- =====================================================================
-- 3 · Programar la copia el día 2 de cada mes a las 04:00 (hora de Madrid ≈ 03:00 UTC)
-- Antes: Database → Extensions → activar pg_cron y pg_net.
-- Cambia TU_CLAVE_ANON (Settings → API → anon public) y TU_SECRETO (el mismo que pongas
-- en el secreto COPIA_SECRETO de la función). Ejecuta solo este bloque cuando lo tengas:
-- =====================================================================
-- select cron.schedule('copia-mensual', '0 3 2 * *', $cron$
--   select net.http_post(
--     url := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/copia-mensual',
--     headers := jsonb_build_object('Content-Type', 'application/json',
--                                   'Authorization', 'Bearer TU_CLAVE_ANON',
--                                   'x-copia-secreto', 'TU_SECRETO'),
--     body := '{}'::jsonb,
--     timeout_milliseconds := 120000)
-- $cron$);
