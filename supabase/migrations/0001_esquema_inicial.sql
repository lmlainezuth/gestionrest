-- =====================================================================
-- GestiónRest · Esquema inicial (Supabase / PostgreSQL)
-- Migrado desde FIDERESTAURANT (SQL Server, RestCsharp)
--
-- Claves primarias UUID: necesarias para PowerSync (los dispositivos crean
-- registros sin conexión y no pueden depender de un IDENTITY del servidor).
--
-- Equivalencias con el sistema anterior:
--   EMPRESA              -> empresa
--   Usuarios + Permisos  -> perfiles (rol: admin | camarero | cocinero)
--   SALON                -> salones
--   Mesas + Propiedades  -> mesas (pos_x, pos_y)
--   Grupo_de_Productos   -> grupos_productos
--   AreasImpresion       -> areas_preparacion (cocina, barra...)
--   Producto1            -> productos
--   Modificadores        -> modificadores
--   clientes             -> clientes
--   Caja                 -> cajas
--   MovimientosCaja      -> turnos_caja
--   ventas               -> pedidos (+ pagos, para cobro mixto)
--   detalle_venta        -> pedido_detalle
--   Detallemodificadores -> pedido_detalle_modificadores
--   ConceptosGastos      -> conceptos_gasto
--   Gastosvarios + Ingresosvarios -> movimientos_caja
-- Descartado: Sunat/SAR, ubigeos, notas de crédito/débito, licencias,
-- serialización, impresoras por PC (se resolverá en la app).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Empresa (una sola fila)
-- ---------------------------------------------------------------------
create table public.empresa (
  id                    uuid primary key default gen_random_uuid(),
  nombre                text not null,
  documento_fiscal      text,
  direccion             text,
  telefono              text,
  logo_url              text,
  simbolo_moneda        text not null default '€',
  impuesto_nombre       text not null default 'IVA',
  impuesto_porcentaje   numeric(5,2) not null default 10,
  trabaja_con_impuestos boolean not null default true,
  creado_en             timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Perfiles de usuario (vinculados a auth.users)
-- ---------------------------------------------------------------------
create table public.perfiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nombre     text not null,
  correo     text,
  rol        text not null default 'camarero'
             check (rol in ('admin','camarero','cocinero')),
  activo     boolean not null default false,   -- el admin lo activa
  icono_url  text,
  creado_en  timestamptz not null default now()
);

-- Rol del usuario actual (null si no existe o está inactivo)
create or replace function public.mi_rol()
returns text
language sql stable security definer
set search_path = ''
as $$
  select p.rol from public.perfiles p
  where p.id = auth.uid() and p.activo
$$;

-- Crea el perfil al registrarse. Nunca toma el rol de los metadatos
-- del cliente: entra como camarero inactivo hasta que el admin lo active.
create or replace function public.crear_perfil()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  insert into public.perfiles (id, nombre, correo)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)),
          new.email);
  return new;
end $$;

create trigger al_crear_usuario
after insert on auth.users
for each row execute function public.crear_perfil();

-- ---------------------------------------------------------------------
-- Salones y mesas
-- ---------------------------------------------------------------------
create table public.salones (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,
  orden     int  not null default 0,
  activo    boolean not null default true,
  creado_en timestamptz not null default now()
);

create table public.mesas (
  id             uuid primary key default gen_random_uuid(),
  salon_id       uuid not null references public.salones(id),
  nombre         text not null,
  capacidad      int,
  disponibilidad text not null default 'libre'
                 check (disponibilidad in ('libre','ocupada','reservada')),
  pos_x          int not null default 0,
  pos_y          int not null default 0,
  activo         boolean not null default true,
  creado_en      timestamptz not null default now()
);
create index on public.mesas (salon_id);

-- ---------------------------------------------------------------------
-- Carta
-- ---------------------------------------------------------------------
create table public.areas_preparacion (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,               -- Cocina, Barra...
  activo    boolean not null default true
);

create table public.grupos_productos (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,
  color     text,                        -- hex, p. ej. #2E7D32
  icono_url text,
  orden     int not null default 0,
  activo    boolean not null default true,
  creado_en timestamptz not null default now()
);

create table public.productos (
  id               uuid primary key default gen_random_uuid(),
  grupo_id         uuid not null references public.grupos_productos(id),
  area_id          uuid references public.areas_preparacion(id),
  nombre           text not null,
  codigo           text,
  precio_venta     numeric(12,2) not null check (precio_venta >= 0),
  precio_compra    numeric(12,2) not null default 0,
  imagen_url       text,
  color            text,
  activo           boolean not null default true,
  creado_en        timestamptz not null default now()
);
create index on public.productos (grupo_id);
create index on public.productos (area_id);

create table public.modificadores (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,               -- "Sin cebolla", "Extra queso"
  precio    numeric(12,2) not null default 0,
  activo    boolean not null default true
);

-- ---------------------------------------------------------------------
-- Clientes
-- ---------------------------------------------------------------------
create table public.clientes (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  documento  text,
  telefono   text,
  direccion  text,
  saldo      numeric(12,2) not null default 0,
  activo     boolean not null default true,
  creado_en  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Caja
-- ---------------------------------------------------------------------
create table public.cajas (
  id        uuid primary key default gen_random_uuid(),
  nombre    text not null,
  activo    boolean not null default true
);

create table public.turnos_caja (
  id                  uuid primary key default gen_random_uuid(),
  caja_id             uuid not null references public.cajas(id),
  usuario_id          uuid not null references public.perfiles(id),
  abierto_en          timestamptz not null default now(),
  cerrado_en          timestamptz,
  efectivo_inicial    numeric(12,2) not null default 0,
  efectivo_calculado  numeric(12,2),
  efectivo_real       numeric(12,2),
  diferencia          numeric(12,2),
  estado              text not null default 'abierto'
                      check (estado in ('abierto','cerrado'))
);
create index on public.turnos_caja (caja_id);
create index on public.turnos_caja (usuario_id);
-- Solo un turno abierto por caja
create unique index turno_abierto_por_caja
  on public.turnos_caja (caja_id) where estado = 'abierto';

create table public.conceptos_gasto (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null,
  activo  boolean not null default true
);

create table public.movimientos_caja (
  id           uuid primary key default gen_random_uuid(),
  turno_id     uuid not null references public.turnos_caja(id),
  tipo         text not null check (tipo in ('ingreso','gasto')),
  concepto_id  uuid references public.conceptos_gasto(id),
  importe      numeric(12,2) not null check (importe > 0),
  descripcion  text,
  usuario_id   uuid not null references public.perfiles(id),
  creado_en    timestamptz not null default now()
);
create index on public.movimientos_caja (turno_id);
create index on public.movimientos_caja (concepto_id);
create index on public.movimientos_caja (usuario_id);

-- ---------------------------------------------------------------------
-- Pedidos (comandas) y cobro
-- ---------------------------------------------------------------------
create table public.pedidos (
  id             uuid primary key default gen_random_uuid(),
  numero         bigint generated always as identity,  -- nº visible en ticket
  tipo           text not null default 'mesa'
                 check (tipo in ('mesa','llevar')),
  mesa_id        uuid references public.mesas(id),
  nombre_llevar  text,
  num_personas   int,
  cliente_id     uuid references public.clientes(id),
  camarero_id    uuid references public.perfiles(id),
  turno_id       uuid references public.turnos_caja(id),  -- se asigna al cobrar
  estado         text not null default 'abierto'
                 check (estado in ('abierto','precuenta','pagado','anulado')),
  nota           text,
  subtotal       numeric(12,2) not null default 0,
  impuesto       numeric(12,2) not null default 0,
  total          numeric(12,2) not null default 0,
  creado_en      timestamptz not null default now(),
  pagado_en      timestamptz,
  check (tipo = 'llevar' or mesa_id is not null)
);
create index on public.pedidos (mesa_id);
create index on public.pedidos (cliente_id);
create index on public.pedidos (camarero_id);
create index on public.pedidos (turno_id);
create index on public.pedidos (estado);

create table public.pedido_detalle (
  id               uuid primary key default gen_random_uuid(),
  pedido_id        uuid not null references public.pedidos(id) on delete cascade,
  producto_id      uuid not null references public.productos(id),
  area_id          uuid references public.areas_preparacion(id),
  descripcion      text not null,          -- copia del nombre al pedir
  cantidad         numeric(10,2) not null check (cantidad > 0),
  precio_unitario  numeric(12,2) not null,
  nota             text,
  estado_cocina    text not null default 'pendiente'
                   check (estado_cocina in ('pendiente','preparando','listo','servido','anulado')),
  creado_en        timestamptz not null default now(),
  listo_en         timestamptz
);
create index on public.pedido_detalle (pedido_id);
create index on public.pedido_detalle (producto_id);
create index on public.pedido_detalle (area_id);
create index on public.pedido_detalle (estado_cocina);

create table public.pedido_detalle_modificadores (
  id              uuid primary key default gen_random_uuid(),
  detalle_id      uuid not null references public.pedido_detalle(id) on delete cascade,
  modificador_id  uuid references public.modificadores(id),
  nombre          text not null,
  precio          numeric(12,2) not null default 0
);
create index on public.pedido_detalle_modificadores (detalle_id);
create index on public.pedido_detalle_modificadores (modificador_id);

create table public.pagos (
  id          uuid primary key default gen_random_uuid(),
  pedido_id   uuid not null references public.pedidos(id),
  turno_id    uuid not null references public.turnos_caja(id),
  metodo      text not null check (metodo in ('efectivo','tarjeta','credito')),
  importe     numeric(12,2) not null check (importe > 0),
  pago_con    numeric(12,2),
  vuelto      numeric(12,2),
  referencia  text,
  creado_en   timestamptz not null default now()
);
create index on public.pagos (pedido_id);
create index on public.pagos (turno_id);

-- ---------------------------------------------------------------------
-- Totales del pedido: el servidor los recalcula desde el detalle
-- ---------------------------------------------------------------------
create or replace function public.recalcular_pedido()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_pedido uuid := coalesce(new.pedido_id, old.pedido_id);
  v_sub numeric(12,2);
  v_pct numeric(5,2);
  v_con boolean;
begin
  select coalesce(sum(d.cantidad * (d.precio_unitario +
           coalesce((select sum(m.precio) from public.pedido_detalle_modificadores m
                     where m.detalle_id = d.id), 0))), 0)
    into v_sub
    from public.pedido_detalle d
   where d.pedido_id = v_pedido and d.estado_cocina <> 'anulado';

  select e.impuesto_porcentaje, e.trabaja_con_impuestos
    into v_pct, v_con
    from public.empresa e limit 1;

  -- Precios con impuesto incluido: se desglosa
  update public.pedidos set
    total    = v_sub,
    impuesto = case when coalesce(v_con,false)
                    then round(v_sub - v_sub / (1 + v_pct/100), 2) else 0 end,
    subtotal = case when coalesce(v_con,false)
                    then round(v_sub / (1 + v_pct/100), 2) else v_sub end
  where id = v_pedido;
  return null;
end $$;

create trigger detalle_recalcula
after insert or update or delete on public.pedido_detalle
for each row execute function public.recalcular_pedido();

-- ---------------------------------------------------------------------
-- Seguridad por rol (RLS)
-- ---------------------------------------------------------------------
alter table public.empresa                      enable row level security;
alter table public.perfiles                     enable row level security;
alter table public.salones                      enable row level security;
alter table public.mesas                        enable row level security;
alter table public.areas_preparacion            enable row level security;
alter table public.grupos_productos             enable row level security;
alter table public.productos                    enable row level security;
alter table public.modificadores                enable row level security;
alter table public.clientes                     enable row level security;
alter table public.cajas                        enable row level security;
alter table public.turnos_caja                  enable row level security;
alter table public.conceptos_gasto              enable row level security;
alter table public.movimientos_caja             enable row level security;
alter table public.pedidos                      enable row level security;
alter table public.pedido_detalle               enable row level security;
alter table public.pedido_detalle_modificadores enable row level security;
alter table public.pagos                        enable row level security;

-- Catálogo: lo lee cualquier usuario activo, solo el admin lo modifica
do $$
declare t text;
begin
  foreach t in array array['empresa','salones','areas_preparacion','grupos_productos',
                           'productos','modificadores','cajas','conceptos_gasto']
  loop
    execute format('create policy "leer_%1$s" on public.%1$I for select to authenticated
                    using ((select public.mi_rol()) is not null)', t);
    execute format('create policy "admin_%1$s" on public.%1$I for all to authenticated
                    using ((select public.mi_rol()) = ''admin'')
                    with check ((select public.mi_rol()) = ''admin'')', t);
  end loop;
end $$;

-- Perfiles: cada uno ve el suyo; el admin ve y gestiona todos
create policy "ver_perfil" on public.perfiles for select to authenticated
  using (id = (select auth.uid()) or (select public.mi_rol()) = 'admin');
create policy "admin_perfiles" on public.perfiles for update to authenticated
  using ((select public.mi_rol()) = 'admin')
  with check ((select public.mi_rol()) = 'admin');

-- Mesas: todos leen; admin gestiona; camarero cambia disponibilidad
create policy "leer_mesas" on public.mesas for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy "admin_mesas" on public.mesas for all to authenticated
  using ((select public.mi_rol()) = 'admin')
  with check ((select public.mi_rol()) = 'admin');
create policy "camarero_mesas" on public.mesas for update to authenticated
  using ((select public.mi_rol()) = 'camarero')
  with check ((select public.mi_rol()) = 'camarero');

-- Clientes: admin y camarero
create policy "leer_clientes" on public.clientes for select to authenticated
  using ((select public.mi_rol()) in ('admin','camarero'));
create policy "escribir_clientes" on public.clientes for all to authenticated
  using ((select public.mi_rol()) in ('admin','camarero'))
  with check ((select public.mi_rol()) in ('admin','camarero'));

-- Pedidos: todos leen (cocina incluida); admin y camarero crean/editan
create policy "leer_pedidos" on public.pedidos for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy "insertar_pedidos" on public.pedidos for insert to authenticated
  with check ((select public.mi_rol()) in ('admin','camarero'));
create policy "editar_pedidos" on public.pedidos for update to authenticated
  using ((select public.mi_rol()) in ('admin','camarero'))
  with check ((select public.mi_rol()) in ('admin','camarero'));
create policy "borrar_pedidos" on public.pedidos for delete to authenticated
  using ((select public.mi_rol()) = 'admin');

-- Detalle: todos leen; admin y camarero añaden; cocina actualiza estado
create policy "leer_detalle" on public.pedido_detalle for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy "insertar_detalle" on public.pedido_detalle for insert to authenticated
  with check ((select public.mi_rol()) in ('admin','camarero'));
create policy "editar_detalle" on public.pedido_detalle for update to authenticated
  using ((select public.mi_rol()) is not null)
  with check ((select public.mi_rol()) is not null);
create policy "borrar_detalle" on public.pedido_detalle for delete to authenticated
  using ((select public.mi_rol()) in ('admin','camarero'));

create policy "leer_det_mod" on public.pedido_detalle_modificadores for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy "escribir_det_mod" on public.pedido_detalle_modificadores for all to authenticated
  using ((select public.mi_rol()) in ('admin','camarero'))
  with check ((select public.mi_rol()) in ('admin','camarero'));

-- El cocinero solo puede tocar estado_cocina y listo_en
create or replace function public.limitar_cocinero()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.mi_rol() = 'cocinero' and
     (new.pedido_id, new.producto_id, new.cantidad, new.precio_unitario,
      new.descripcion, new.nota, new.area_id)
     is distinct from
     (old.pedido_id, old.producto_id, old.cantidad, old.precio_unitario,
      old.descripcion, old.nota, old.area_id) then
    raise exception 'El cocinero solo puede cambiar el estado del plato';
  end if;
  return new;
end $$;

create trigger detalle_limita_cocinero
before update on public.pedido_detalle
for each row execute function public.limitar_cocinero();

-- Caja (turnos, pagos, ingresos/gastos): solo admin
do $$
declare t text;
begin
  foreach t in array array['turnos_caja','movimientos_caja','pagos']
  loop
    execute format('create policy "admin_%1$s" on public.%1$I for all to authenticated
                    using ((select public.mi_rol()) = ''admin'')
                    with check ((select public.mi_rol()) = ''admin'')', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Datos base
-- ---------------------------------------------------------------------
insert into public.empresa (nombre) values ('Ezer Gaizk');
insert into public.areas_preparacion (nombre) values ('Cocina'), ('Barra');
insert into public.cajas (nombre) values ('Caja principal');
