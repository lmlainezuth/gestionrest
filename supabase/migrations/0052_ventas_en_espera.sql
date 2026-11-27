-- 0052 · Ventas sin internet en espera (contingencia de TicketBAI).
-- Si al subir una venta hecha sin internet el servidor no la acepta (firma o cadena), el equipo la
-- deja en ventas_espera (función "ticketbai", acción apartar) con todo lo que tiene: pedido,
-- líneas, cobros y la factura firmada. El administrador la resuelve desde cualquier equipo
-- (Facturas › Ventas en espera): la envía a Hacienda tal cual, con un motivo, y queda
-- factura_forzada en Seguridad. Si rompía la cadena, se guarda marcada "fuera de cadena".
--  · ventas_espera solo admite altas, y solo por el servidor: nadie la edita ni la borra desde la
--    app (tampoco el administrador). Ficheros de 200 KB como mucho y solo del NIF del bar.
--  · Resuelta = ya existe la factura con el mismo id.
-- Necesita la 0050. Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Tabla de ventas en espera
-- =====================================================================
create table if not exists public.ventas_espera (
  id              uuid primary key,              -- el id de la factura emitida sin internet
  empresa_id      uuid not null references public.empresa(id) on delete cascade,
  creado_en       timestamptz not null default now(),
  usuario_id      uuid,                          -- quien estaba en el equipo al subirla
  serie           text not null,
  numero          int not null,
  fecha           timestamptz,
  importe         numeric(12,2),
  motivo_rechazo  text check (char_length(motivo_rechazo) <= 1000),
  venta           jsonb not null check (octet_length(venta::text) <= 600000),
  xml             text not null check (octet_length(xml) <= 200000)
);
create index if not exists ventas_espera_empresa_idx on public.ventas_espera (empresa_id, creado_en);

alter table public.ventas_espera enable row level security;
-- La ve el administrador de su bar. Sin políticas de escritura: solo escribe el servidor
drop policy if exists "admin_ver_ventas_espera" on public.ventas_espera;
create policy "admin_ver_ventas_espera" on public.ventas_espera for select to authenticated
  using (empresa_id = (select public.empresa_actual()) and (select public.mi_rol()) = 'admin');
revoke all on public.ventas_espera from anon;
revoke insert, update, delete on public.ventas_espera from authenticated;

-- Solo altas, y solo ficheros del NIF del bar
create or replace function public.ventas_espera_solo_altas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nif text;
  v_emisor text;
begin
  if tg_op = 'UPDATE' then
    raise exception 'Una venta en espera no se cambia';
  end if;
  if tg_op = 'DELETE' then
    -- Solo desde el SQL Editor (sin sesión de usuario ni clave de servicio), para mantenimiento
    if auth.role() is not null then
      raise exception 'Una venta en espera no se borra';
    end if;
    return old;
  end if;
  select upper(trim(c.nif)) into v_nif from public.tbai_config c where c.empresa_id = new.empresa_id;
  v_emisor := upper(trim(substring(new.xml from '<(?:[\w.-]+:)?Emisor>\s*<(?:[\w.-]+:)?NIF>([^<]*)<')));
  if v_nif is null or v_emisor is distinct from v_nif then
    raise exception 'El fichero no es del NIF del bar';
  end if;
  return new;
end $$;
revoke all on function public.ventas_espera_solo_altas() from public, anon, authenticated;
drop trigger if exists ventas_espera_solo_altas on public.ventas_espera;
create trigger ventas_espera_solo_altas before insert or update or delete on public.ventas_espera
for each row execute function public.ventas_espera_solo_altas();

-- ¿Ya está resuelta (hay factura con su id)? Para el equipo que la dejó en espera
create or replace function public.venta_espera_resuelta(p_id uuid)
returns boolean
language sql stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.facturas f
                  where f.id = p_id and f.empresa_id = (select public.empresa_actual()))
     and (select public.mi_rol()) in ('admin', 'camarero')
$$;
revoke all on function public.venta_espera_resuelta(uuid) from public, anon;
grant execute on function public.venta_espera_resuelta(uuid) to authenticated;

-- =====================================================================
-- 2 · Facturas "fuera de cadena": las forzadas que rompían la cadena
-- =====================================================================
alter table public.facturas add column if not exists fuera_de_cadena boolean not null default false;

-- Solo el servidor la pone: la app no inserta facturas salvo las de legado del administrador
drop policy if exists "emitir_facturas" on public.facturas;
create policy "emitir_facturas" on public.facturas for insert to authenticated
  with check ((select public.mi_rol()) = 'admin' and legado and not fuera_de_cadena);

-- Sin anterior, pero no es la primera de su cadena: no cuenta para "una sola primera por cadena"
drop index if exists public.facturas_primera_por_cadena;
create unique index facturas_primera_por_cadena
  on public.facturas (empresa_id, cadena) where anterior_id is null and not legado and not fuera_de_cadena;

create or replace function public.factura_encadenada()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ultima uuid;
begin
  -- Legado (importadas) y forzadas fuera de cadena (las guarda el servidor tal como se emitieron)
  if new.legado or new.fuera_de_cadena then
    return new;
  end if;
  -- Reintento de una subida que ya llegó (ventas sin internet): lo resuelve el ON CONFLICT
  if exists (select 1 from public.facturas where id = new.id) then
    return new;
  end if;
  -- Dos emisiones a la vez en la misma serie esperan su turno
  perform pg_advisory_xact_lock(hashtext('tbai_cadena:' || new.empresa_id::text || ':' || new.cadena));
  select f.id into v_ultima
    from public.facturas f
   where f.cadena = new.cadena and f.empresa_id = new.empresa_id
     and not exists (select 1 from public.facturas g where g.anterior_id = f.id and g.empresa_id = new.empresa_id)
   order by f.legado, f.fecha desc, f.creado_en desc
   limit 1;
  if new.anterior_id is distinct from v_ultima then
    -- 23505: la app lo trata como "otro equipo emitió a la vez" y vuelve a leer la última
    raise exception 'La serie % ha avanzado mientras se emitía: vuelve a intentarlo', new.cadena
      using errcode = '23505';
  end if;
  return new;
end $$;
revoke all on function public.factura_encadenada() from public, anon, authenticated;
