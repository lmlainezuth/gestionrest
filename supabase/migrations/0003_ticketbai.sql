-- =====================================================================
-- GestiónRest · TicketBAI (Gipuzkoa)
-- Facturas encadenadas, inmutables, con identificador TBAI y QR.
-- La firma y el envío los hace un "proveedor" intercambiable:
--   simulado  -> firma de prueba, no se envía a Hacienda (tesis)
--   pruebas / produccion -> proveedor certificado (futuro)
-- =====================================================================

create table public.tbai_config (
  id                 uuid primary key default gen_random_uuid(),
  nif                text not null check (length(nif) = 9),
  razon_social       text not null,
  entorno            text not null default 'simulado'
                     check (entorno in ('simulado','pruebas','produccion')),
  licencia_tbai      text,            -- la asigna la Hacienda Foral al registrar el software
  nif_desarrollador  text,
  nombre_software    text not null default 'GestionRest',
  version_software   text not null default '1.0',
  tipo_iva           numeric(5,2) not null default 10
);

-- Cada caja factura con su propia serie (permite facturar sin conexión)
alter table public.cajas add column serie_factura text not null default 'T1';

create table public.facturas (
  id                  uuid primary key default gen_random_uuid(),
  pedido_id           uuid unique references public.pedidos(id),
  caja_id             uuid references public.cajas(id),
  serie               text not null,
  numero              int  not null check (numero > 0),
  fecha               timestamptz not null,
  tipo                text not null default 'simplificada'
                      check (tipo in ('simplificada','completa')),
  nif_emisor          text not null,
  razon_social_emisor text not null,
  cliente_nif         text,
  cliente_nombre      text,
  lineas              jsonb not null,
  base_imponible      numeric(12,2) not null,
  tipo_iva            numeric(5,2)  not null,
  cuota_iva           numeric(12,2) not null,
  importe_total       numeric(12,2) not null,
  -- Encadenamiento con la factura anterior de la misma serie
  anterior_serie      text,
  anterior_numero     int,
  anterior_fecha      timestamptz,
  anterior_firma100   text,          -- 100 primeros caracteres de su SignatureValue
  -- Resultado TicketBAI
  firma               text not null, -- SignatureValue
  tbai_id             text not null check (length(tbai_id) = 39),
  qr_url              text not null,
  xml                 text not null,
  estado_envio        text not null default 'pendiente'
                      check (estado_envio in ('pendiente','enviada','error','simulada')),
  respuesta_envio     text,
  creado_por          uuid references public.perfiles(id),
  creado_en           timestamptz not null default now(),
  unique (serie, numero),
  check (tipo = 'simplificada' or cliente_nif is not null)
);
create index on public.facturas (caja_id);
create index on public.facturas (creado_por);
create index on public.facturas (fecha);

-- Una factura emitida no se modifica ni se borra (solo su estado de envío)
create or replace function public.factura_inmutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Una factura emitida no se puede borrar (emite una rectificativa)';
  end if;
  if (to_jsonb(new) - 'estado_envio' - 'respuesta_envio')
     is distinct from (to_jsonb(old) - 'estado_envio' - 'respuesta_envio') then
    raise exception 'Una factura emitida no se puede modificar';
  end if;
  return new;
end $$;

create trigger facturas_inmutables
before update or delete on public.facturas
for each row execute function public.factura_inmutable();

alter table public.tbai_config enable row level security;
alter table public.facturas    enable row level security;

create policy "leer_tbai_config" on public.tbai_config for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy "admin_tbai_config" on public.tbai_config for all to authenticated
  using ((select public.mi_rol()) = 'admin')
  with check ((select public.mi_rol()) = 'admin');

create policy "leer_facturas" on public.facturas for select to authenticated
  using ((select public.mi_rol()) = 'admin');
create policy "emitir_facturas" on public.facturas for insert to authenticated
  with check ((select public.mi_rol()) = 'admin');
create policy "estado_facturas" on public.facturas for update to authenticated
  using ((select public.mi_rol()) = 'admin')
  with check ((select public.mi_rol()) = 'admin');

-- Datos del emisor: CAMBIA el NIF y la razón social por los reales
insert into public.tbai_config (nif, razon_social) values ('B00000000', 'EZER GAIZK [RAZÓN SOCIAL]');
