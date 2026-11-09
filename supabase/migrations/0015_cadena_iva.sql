-- 0015 · TicketBAI: una sola cadena por punto de emisión (todas sus series) e IVA por producto.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.
--
-- Norma (FAQ Gipuzkoa "Encadenamiento por series"): si un mismo dispositivo emite varias
-- series (tickets, facturas con NIF, rectificativas) se encadena con la factura anterior
-- sea de la serie que sea. Cada punto de emisión ("cadena") = su serie base (T1, B1…).

-- 1 · Cadena y enlace con la factura anterior --------------------------------------
alter table public.facturas add column if not exists cadena      text;
alter table public.facturas add column if not exists anterior_id uuid references public.facturas(id);
alter table public.facturas add column if not exists legado      boolean not null default false;
-- Desglose por tipo de IVA: [{tipo, base, cuota}]
alter table public.facturas add column if not exists desglose_iva jsonb;

-- Las facturas ya emitidas (pruebas) se marcan como "legado": su cadena era por serie
alter table public.facturas disable trigger facturas_inmutables;
update public.facturas
   set legado = true,
       cadena = coalesce(cadena, regexp_replace(serie, '[FR]$', '')),
       desglose_iva = coalesce(desglose_iva,
         jsonb_build_array(jsonb_build_object('tipo', tipo_iva, 'base', base_imponible, 'cuota', cuota_iva)))
 where cadena is null or desglose_iva is null;
alter table public.facturas enable trigger facturas_inmutables;

alter table public.facturas alter column cadena set not null;

-- Una factura solo puede ser "la anterior" de otra: impide bifurcar la cadena aunque dos
-- equipos cobren a la vez (el segundo recibe 23505 y reintenta con la nueva última)
create unique index if not exists facturas_anterior_unica
  on public.facturas (anterior_id) where anterior_id is not null;
-- Solo una factura sin anterior (la primera) por cadena y empresa
create unique index if not exists facturas_primera_por_cadena
  on public.facturas (empresa_id, cadena) where anterior_id is null and not legado;
create index if not exists facturas_cadena_idx on public.facturas (empresa_id, cadena, fecha desc);

-- Última factura de una cadena: la que ninguna otra tiene como anterior
create or replace function public.tbai_ultima_factura(p_cadena text)
returns setof public.facturas
language sql stable
security invoker
set search_path = ''
as $$
  select f.* from public.facturas f
   where f.cadena = p_cadena
     and f.empresa_id = (select public.empresa_actual())
     and not exists (select 1 from public.facturas g where g.anterior_id = f.id)
   order by f.legado, f.fecha desc, f.creado_en desc
   limit 1
$$;
grant execute on function public.tbai_ultima_factura(text) to authenticated;

-- 2 · IVA por producto ---------------------------------------------------------------
-- Hostelería (consumo en el local) 10 %. Para llevar: refrescos azucarados, alcohol y
-- tabaco 21 %; pan y leche 4 %.
alter table public.productos add column if not exists tipo_iva numeric(5,2) not null default 10
  check (tipo_iva in (0, 4, 5, 10, 21));
alter table public.pedido_detalle add column if not exists tipo_iva numeric(5,2);

-- Si la app no manda el IVA de la línea, se copia del producto
create or replace function public.detalle_tipo_iva()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.tipo_iva is null then
    select p.tipo_iva into new.tipo_iva from public.productos p where p.id = new.producto_id;
    new.tipo_iva := coalesce(new.tipo_iva, 10);
  end if;
  return new;
end $$;
drop trigger if exists detalle_tipo_iva on public.pedido_detalle;
create trigger detalle_tipo_iva before insert on public.pedido_detalle
for each row execute function public.detalle_tipo_iva();
update public.pedido_detalle set tipo_iva = 10 where tipo_iva is null;

-- 3 · Reenvío automático sin duplicados -----------------------------------------------
-- Un equipo "reclama" la factura antes de reenviarla: si dos equipos lo intentan a la vez,
-- solo uno la envía (los demás esperan 2 minutos).
alter table public.facturas         add column if not exists envio_intento timestamptz;
alter table public.tbai_anulaciones add column if not exists envio_intento timestamptz;

create or replace function public.factura_inmutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Una factura emitida no se puede borrar (emite una rectificativa)';
  end if;
  if (to_jsonb(new) - 'estado_envio' - 'respuesta_envio' - 'envio_intento')
     is distinct from (to_jsonb(old) - 'estado_envio' - 'respuesta_envio' - 'envio_intento') then
    raise exception 'Una factura emitida no se puede modificar';
  end if;
  return new;
end $$;

create or replace function public.tbai_reclamar_envio(p_tabla text, p_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  n int := 0;
begin
  if p_tabla = 'facturas' then
    update public.facturas set envio_intento = now()
     where id = p_id and estado_envio in ('pendiente', 'error')
       and (envio_intento is null or envio_intento < now() - interval '2 minutes');
  elsif p_tabla = 'anulaciones' then
    update public.tbai_anulaciones set envio_intento = now()
     where id = p_id and estado_envio in ('pendiente', 'error')
       and (envio_intento is null or envio_intento < now() - interval '2 minutes');
  end if;
  get diagnostics n = row_count;
  return n = 1;
end $$;
grant execute on function public.tbai_reclamar_envio(text, uuid) to authenticated;
