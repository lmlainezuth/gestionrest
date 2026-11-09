-- 0014 · TicketBAI: anulaciones, facturas rectificativas y sustitución de simplificadas
-- Se puede ejecutar más de una vez.

-- Tipos de factura: se añade la rectificativa (puede ser de un ticket, sin NIF)
alter table public.facturas drop constraint if exists facturas_tipo_check;
alter table public.facturas add constraint facturas_tipo_check
  check (tipo in ('simplificada', 'completa', 'rectificativa'));
alter table public.facturas drop constraint if exists facturas_check;
alter table public.facturas add constraint facturas_check
  check (tipo in ('simplificada', 'rectificativa') or cliente_nif is not null);

-- A qué factura rectifica o sustituye
alter table public.facturas add column if not exists rectifica_id uuid references public.facturas(id);
alter table public.facturas add column if not exists rectificativa_codigo text
  check (rectificativa_codigo in ('R1', 'R2', 'R3', 'R4', 'R5'));
alter table public.facturas add column if not exists sustituye_simplificada boolean not null default false;
create index if not exists facturas_rectifica_idx on public.facturas (rectifica_id);

-- Anulaciones enviadas a Hacienda (la factura nunca se borra)
create table if not exists public.tbai_anulaciones (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  factura_id      uuid not null unique references public.facturas(id),
  fecha           timestamptz not null default now(),
  motivo          text,
  xml             text not null,
  firma           text not null,
  estado_envio    text not null default 'pendiente' check (estado_envio in ('pendiente', 'enviada', 'error', 'simulada')),
  respuesta_envio text,
  creado_por      uuid default auth.uid() references public.perfiles(id)
);
create index if not exists tbai_anulaciones_empresa_idx on public.tbai_anulaciones (empresa_id);

alter table public.tbai_anulaciones enable row level security;
drop policy if exists "leer_anulaciones" on public.tbai_anulaciones;
create policy "leer_anulaciones" on public.tbai_anulaciones for select to authenticated
  using ((select public.mi_rol()) is not null);
drop policy if exists "admin_anulaciones" on public.tbai_anulaciones;
create policy "admin_anulaciones" on public.tbai_anulaciones for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');
drop policy if exists "por_empresa" on public.tbai_anulaciones;
create policy "por_empresa" on public.tbai_anulaciones as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()))
  with check (empresa_id = (select public.empresa_actual()));
