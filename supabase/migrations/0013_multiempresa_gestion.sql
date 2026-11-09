-- =====================================================================
-- GestiónRest · Multi-empresa + módulo de gestión (lo que hacía Yitso)
--
-- Cada usuario elige su "empresa actual" (perfiles.empresa_actual).
-- Todas las tablas llevan empresa_id, que se rellena solo al insertar,
-- y una política restrictiva hace que cada usuario vea y toque únicamente
-- los datos de su empresa actual. Rol y permisos pasan a ser por empresa.
-- =====================================================================

-- ---------- Miembros de cada empresa ----------
create table public.empresa_usuarios (
  empresa_id  uuid not null references public.empresa(id) on delete cascade,
  usuario_id  uuid not null references public.perfiles(id) on delete cascade,
  rol         text not null default 'camarero' check (rol in ('admin','camarero','cocinero')),
  activo      boolean not null default true,
  permisos    text[],
  primary key (empresa_id, usuario_id)
);
create index on public.empresa_usuarios (usuario_id);

alter table public.perfiles add column empresa_actual uuid references public.empresa(id) on delete set null;
create index on public.perfiles (empresa_actual);

-- Los usuarios que ya existían pasan a la empresa actual con su rol
insert into public.empresa_usuarios (empresa_id, usuario_id, rol, activo, permisos)
select (select id from public.empresa order by creado_en limit 1), p.id, p.rol, p.activo, p.permisos
from public.perfiles p;
update public.perfiles set empresa_actual = (select id from public.empresa order by creado_en limit 1);

-- ---------- Empresa actual y rol en ella ----------
create or replace function public.empresa_actual()
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select p.empresa_actual
  from public.perfiles p
  join public.empresa_usuarios eu
    on eu.empresa_id = p.empresa_actual and eu.usuario_id = p.id and eu.activo
  where p.id = auth.uid()
$$;

create or replace function public.mi_rol()
returns text
language sql stable security definer
set search_path = ''
as $$
  select eu.rol
  from public.perfiles p
  join public.empresa_usuarios eu
    on eu.empresa_id = p.empresa_actual and eu.usuario_id = p.id and eu.activo
  where p.id = auth.uid()
$$;

-- ---------- empresa_id en todas las tablas de datos ----------
-- Las facturas son inmutables: se suspende la protección solo para asignarles la empresa
alter table public.facturas disable trigger facturas_inmutables;

do $$
declare
  t text;
  e uuid := (select id from public.empresa order by creado_en limit 1);
begin
  foreach t in array array['tbai_config','salones','mesas','areas_preparacion','grupos_productos','productos',
                           'modificadores','producto_modificadores','clientes','cajas','turnos_caja',
                           'conceptos_gasto','movimientos_caja','pedidos','pedido_detalle','pagos','facturas']
  loop
    execute format('alter table public.%I add column empresa_id uuid references public.empresa(id) on delete cascade', t);
    execute format('update public.%I set empresa_id = %L', t, e);
    execute format('alter table public.%I alter column empresa_id set not null', t);
    execute format('alter table public.%I alter column empresa_id set default public.empresa_actual()', t);
    execute format('create index on public.%I (empresa_id)', t);
    execute format('create policy "por_empresa" on public.%I as restrictive for all to authenticated
                    using (empresa_id = (select public.empresa_actual()))
                    with check (empresa_id = (select public.empresa_actual()))', t);
  end loop;
end $$;

alter table public.facturas enable trigger facturas_inmutables;

-- Numeración de facturas y configuración TicketBAI: por empresa
alter table public.facturas drop constraint facturas_serie_numero_key;
alter table public.facturas add constraint facturas_empresa_serie_numero_key unique (empresa_id, serie, numero);
alter table public.tbai_config add constraint tbai_config_empresa_key unique (empresa_id);

-- La tabla empresa: cada uno solo ve y edita la suya actual
create policy "empresa_actual" on public.empresa as restrictive for all to authenticated
  using (id = (select public.empresa_actual()))
  with check (id = (select public.empresa_actual()));

-- Perfiles: el propio, o los de mi empresa si soy admin
drop policy "ver_perfil" on public.perfiles;
drop policy "admin_perfiles" on public.perfiles;
create policy "ver_perfil" on public.perfiles for select to authenticated
  using (
    id = (select auth.uid())
    or ((select public.mi_rol()) = 'admin' and exists (
      select 1 from public.empresa_usuarios eu
      where eu.usuario_id = perfiles.id and eu.empresa_id = (select public.empresa_actual())))
  );

-- Miembros: el admin de la empresa actual los gestiona
alter table public.empresa_usuarios enable row level security;
create policy "ver_miembros" on public.empresa_usuarios for select to authenticated
  using (empresa_id = (select public.empresa_actual())
         and (usuario_id = (select auth.uid()) or (select public.mi_rol()) = 'admin'));
create policy "admin_miembros" on public.empresa_usuarios for all to authenticated
  using (empresa_id = (select public.empresa_actual()) and (select public.mi_rol()) = 'admin')
  with check (empresa_id = (select public.empresa_actual()) and (select public.mi_rol()) = 'admin');

-- El IVA del pedido sale de la empresa del pedido
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
    from public.pedidos p join public.empresa e on e.id = p.empresa_id
   where p.id = v_pedido;

  update public.pedidos set
    total    = v_sub,
    impuesto = case when coalesce(v_con,false) then round(v_sub - v_sub / (1 + v_pct/100), 2) else 0 end,
    subtotal = case when coalesce(v_con,false) then round(v_sub / (1 + v_pct/100), 2) else v_sub end
  where id = v_pedido;
  return null;
end $$;

-- ---------- Funciones para la app ----------
-- Mi perfil en la empresa actual
create or replace function public.mi_perfil()
returns table (id uuid, nombre text, correo text, rol text, activo boolean, permisos text[],
               empresa_id uuid, empresa_nombre text)
language sql stable security definer
set search_path = ''
as $$
  select p.id, p.nombre, p.correo, eu.rol, coalesce(eu.activo, false), eu.permisos, e.id, e.nombre
  from public.perfiles p
  left join public.empresa_usuarios eu on eu.empresa_id = p.empresa_actual and eu.usuario_id = p.id
  left join public.empresa e on e.id = p.empresa_actual
  where p.id = auth.uid()
$$;

-- Empresas a las que tengo acceso
create or replace function public.mis_empresas()
returns table (id uuid, nombre text, rol text)
language sql stable security definer
set search_path = ''
as $$
  select e.id, e.nombre, eu.rol
  from public.empresa_usuarios eu join public.empresa e on e.id = eu.empresa_id
  where eu.usuario_id = auth.uid() and eu.activo
  order by e.nombre
$$;

-- Cambiar de empresa (solo a una donde sea miembro activo)
create or replace function public.usar_empresa(p_empresa uuid)
returns boolean
language plpgsql security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.empresa_usuarios
                 where empresa_id = p_empresa and usuario_id = auth.uid() and activo) then
    return false;
  end if;
  update public.perfiles set empresa_actual = p_empresa where id = auth.uid();
  return true;
end $$;

-- Equipo de la empresa actual (pantalla Usuarios)
create or replace function public.equipo_empresa()
returns table (id uuid, nombre text, correo text, rol text, activo boolean, permisos text[])
language sql stable security definer
set search_path = ''
as $$
  select p.id, p.nombre, p.correo, eu.rol, eu.activo, eu.permisos
  from public.empresa_usuarios eu join public.perfiles p on p.id = eu.usuario_id
  where eu.empresa_id = public.empresa_actual() and public.mi_rol() = 'admin'
  order by eu.activo, p.nombre
$$;

-- Nueva empresa: quien la crea queda como admin
create or replace function public.crear_empresa(p_nombre text, p_nif text default 'B00000000')
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare v uuid;
begin
  if public.mi_rol() is distinct from 'admin' then
    raise exception 'Solo un administrador puede crear empresas';
  end if;
  insert into public.empresa (nombre) values (p_nombre) returning id into v;
  insert into public.empresa_usuarios (empresa_id, usuario_id, rol) values (v, auth.uid(), 'admin');
  insert into public.tbai_config (empresa_id, nif, razon_social) values (v, p_nif, p_nombre);
  insert into public.areas_preparacion (empresa_id, nombre) values (v, 'Cocina'), (v, 'Barra');
  insert into public.cajas (empresa_id, nombre) values (v, 'Caja principal');
  insert into public.conceptos_gasto (empresa_id, nombre) values
    (v, 'Proveedor'), (v, 'Cambio / monedas'), (v, 'Limpieza'), (v, 'Reparaciones'), (v, 'Otros');
  return v;
end $$;

-- Pantalla de entrada: equipo de la empresa de este dispositivo
drop function public.equipo_login();
create or replace function public.equipo_login(p_empresa uuid)
returns table (id uuid, nombre text, rol text, correo text)
language sql stable security definer
set search_path = ''
as $$
  select p.id, p.nombre, eu.rol, p.correo
  from public.empresa_usuarios eu join public.perfiles p on p.id = eu.usuario_id
  where eu.empresa_id = p_empresa and eu.activo and p.correo like '%@gestionrest.local'
  order by p.nombre
$$;
grant execute on function public.equipo_login(uuid) to anon, authenticated;

-- ---------- Gestión (antes Yitso) ----------
create table public.proveedores (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  nombre        text not null,
  suministra    text,
  telefono      text,
  iva_habitual  text not null default '10' check (iva_habitual in ('0','4','10','21','mixto')),
  icono         text not null default 'box',
  creado_en     timestamptz not null default now()
);

create table public.gastos (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  proveedor_id  uuid references public.proveedores(id) on delete set null,
  fecha         date not null,
  concepto      text not null,
  importe       numeric(12,2) not null check (importe >= 0),   -- IVA incluido
  categoria     text not null default 'materia' check (categoria in ('fijos','materia','otros')),
  iva_tipo      text not null default '10' check (iva_tipo in ('0','4','10','21','mixto')),
  iva_importe   numeric(12,2),                                  -- solo si es mixto
  estado        text not null default 'registrado' check (estado in ('registrado','pendiente')),
  creado_en     timestamptz not null default now()
);

create table public.cajas_diarias (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  fecha       date not null,
  total       numeric(12,2) not null default 0,
  efectivo    numeric(12,2),
  tarjeta     numeric(12,2),
  estado      text not null default 'cerrada' check (estado in ('cerrada','pendiente')),
  notas       text,
  unique (empresa_id, fecha)
);

create index on public.proveedores (empresa_id);
create index on public.gastos (empresa_id, fecha);
create index on public.gastos (proveedor_id);

do $$
declare t text;
begin
  foreach t in array array['proveedores','gastos','cajas_diarias']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "por_empresa" on public.%I as restrictive for all to authenticated
                    using (empresa_id = (select public.empresa_actual()))
                    with check (empresa_id = (select public.empresa_actual()))', t);
    execute format('create policy "leer_%1$s" on public.%1$I for select to authenticated
                    using ((select public.mi_rol()) in (''admin'',''camarero''))', t);
    execute format('create policy "escribir_%1$s" on public.%1$I for insert to authenticated
                    with check ((select public.mi_rol()) in (''admin'',''camarero''))', t);
    execute format('create policy "editar_%1$s" on public.%1$I for update to authenticated
                    using ((select public.mi_rol()) in (''admin'',''camarero''))
                    with check ((select public.mi_rol()) in (''admin'',''camarero''))', t);
    execute format('create policy "borrar_%1$s" on public.%1$I for delete to authenticated
                    using ((select public.mi_rol()) = ''admin'')', t);
  end loop;
end $$;
