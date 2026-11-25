-- 0026 · Registro de series TicketBAI.
--
-- Para Hacienda una factura es NIF + serie + número. Una serie no puede repetirse para el
-- mismo titular aunque sean bares distintos (dos empresas de la app con el mismo NIF), ni
-- usarse en dos equipos a la vez. Hasta ahora la serie se escribía a mano y cada caja nacía
-- con "T1": dos bares del mismo titular facturaban T1-1, T1-2… y Hacienda los rechazaba.
--
-- Desde aquí las series las asigna la base de datos (A1, B1, C1… por NIF), quedan apuntadas
-- y no se borran ni se reutilizan. En producción no se puede facturar con una serie que no
-- esté asignada a ese bar y ese titular en producción.

-- ---------- Registro ----------
create table if not exists public.tbai_series (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null references public.empresa(id) on delete cascade,
  nif         text not null,
  serie       text not null check (serie ~ '^[A-Z0-9]{1,20}$'),
  tipo        text not null check (tipo in ('caja', 'equipo')),
  descripcion text,
  entorno     text not null check (entorno in ('simulado', 'pruebas', 'produccion')),
  creada_en   timestamptz not null default now(),
  creada_por  uuid default auth.uid() references public.perfiles(id),
  unique (nif, serie)
);
create index if not exists tbai_series_empresa_idx on public.tbai_series (empresa_id);

-- Solo se lee desde la app; se escribe únicamente con las funciones de abajo
alter table public.tbai_series enable row level security;
drop policy if exists "por_empresa" on public.tbai_series;
create policy "por_empresa" on public.tbai_series as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()))
  with check (empresa_id = (select public.empresa_actual()));
drop policy if exists "leer_series" on public.tbai_series;
create policy "leer_series" on public.tbai_series for select to authenticated
  using ((select public.mi_rol()) is not null);

-- Una serie asignada no se modifica
create or replace function public.serie_inmutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Una serie asignada no se modifica';
end $$;
drop trigger if exists tbai_series_inmutable on public.tbai_series;
create trigger tbai_series_inmutable before update on public.tbai_series
  for each row execute function public.serie_inmutable();

-- ---------- Series que ya existen ----------
-- Primero la serie actual de cada caja, después las de las facturas emitidas (equipos).
-- Quedan con el entorno que tiene hoy cada empresa: las de pruebas no valen en producción.
insert into public.tbai_series (empresa_id, nif, serie, tipo, descripcion, entorno, creada_por)
select c.empresa_id, t.nif, upper(c.serie_factura), 'caja', 'Ya existía antes del registro', t.entorno, null
from public.cajas c
join public.tbai_config t on t.empresa_id = c.empresa_id
where upper(c.serie_factura) ~ '^[A-Z0-9]{1,20}$'
on conflict (nif, serie) do nothing;

insert into public.tbai_series (empresa_id, nif, serie, tipo, descripcion, entorno, creada_por)
select distinct on (f.nif_emisor, f.cadena) f.empresa_id, f.nif_emisor, f.cadena, 'equipo',
       'Ya existía antes del registro', t.entorno, null
from public.facturas f
join public.tbai_config t on t.empresa_id = f.empresa_id
where f.cadena ~ '^[A-Z0-9]{1,20}$'
order by f.nif_emisor, f.cadena, f.fecha
on conflict (nif, serie) do nothing;

-- ---------- Asignar una serie nueva ----------
-- Interna: la siguiente libre para el NIF de la empresa (A1…Z1, A2…Z2…). Siempre acaba en
-- número, así nunca choca con los sufijos "F" (factura con NIF) y "R" (rectificativa).
create or replace function public.tbai_nueva_serie(p_empresa uuid, p_tipo text, p_descripcion text default null)
returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nif text;
  v_entorno text;
  v_serie text;
begin
  select t.nif, t.entorno into v_nif, v_entorno from public.tbai_config t where t.empresa_id = p_empresa;
  if v_nif is null then
    raise exception 'La empresa no tiene datos fiscales';
  end if;
  -- Dos asignaciones a la vez para el mismo NIF esperan su turno
  perform pg_advisory_xact_lock(hashtext('tbai_series:' || v_nif));
  <<buscar>>
  for n in 1..99 loop
    for l in 0..25 loop
      if not exists (select 1 from public.tbai_series s where s.nif = v_nif and s.serie = chr(65 + l) || n)
         and not exists (select 1 from public.facturas f where f.nif_emisor = v_nif and f.cadena = chr(65 + l) || n) then
        v_serie := chr(65 + l) || n;
        exit buscar;
      end if;
    end loop;
  end loop;
  if v_serie is null then
    raise exception 'No quedan series libres para el NIF %', v_nif;
  end if;
  insert into public.tbai_series (empresa_id, nif, serie, tipo, descripcion, entorno)
  values (p_empresa, v_nif, v_serie, p_tipo, p_descripcion, v_entorno);
  if p_tipo = 'caja' then
    update public.cajas set serie_factura = v_serie
     where id = (select c.id from public.cajas c where c.empresa_id = p_empresa and c.activo limit 1);
  end if;
  return v_serie;
end $$;
revoke all on function public.tbai_nueva_serie(uuid, text, text) from public, anon, authenticated;

-- Desde la app (solo administrador, empresa actual)
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

-- ¿Puede este equipo facturar con esta serie? (lo mira la app antes de cobrar sin internet)
create or replace function public.tbai_serie_valida(p_serie text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select t.entorno <> 'produccion' or exists (
           select 1 from public.tbai_series s
            where s.empresa_id = t.empresa_id and s.nif = t.nif
              and s.serie = p_serie and s.entorno = 'produccion')
  from public.tbai_config t
  where t.empresa_id = public.empresa_actual()
$$;
revoke all on function public.tbai_serie_valida(text) from public, anon;
grant execute on function public.tbai_serie_valida(text) to authenticated;

-- ---------- En producción, solo series asignadas ----------
create or replace function public.factura_serie_registrada()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
begin
  if new.legado then
    return new;
  end if;
  if (select t.entorno from public.tbai_config t where t.empresa_id = new.empresa_id) = 'produccion'
     and not exists (select 1 from public.tbai_series s
                      where s.empresa_id = new.empresa_id and s.nif = new.nif_emisor
                        and s.serie = new.cadena and s.entorno = 'produccion') then
    raise exception 'La serie % no está asignada a este bar y este titular en producción. Asígnala en Ajustes › Empresa', new.cadena;
  end if;
  return new;
end $$;
drop trigger if exists facturas_serie_registrada on public.facturas;
create trigger facturas_serie_registrada before insert on public.facturas
  for each row execute function public.factura_serie_registrada();

-- ---------- Empresa nueva: la caja nace con su serie asignada ----------
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
  perform public.tbai_nueva_serie(v, 'caja', 'Caja principal');
  return v;
end $$;
