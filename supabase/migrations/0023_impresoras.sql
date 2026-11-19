-- 0023 · Impresoras de la empresa (panel de impresoras)
-- Cada impresora guarda su configuración (tipo, conexión, ancho y perfil ESC/POS) en "config".
-- Los equipos copian la que necesitan y la recuerdan, así imprimen también sin internet.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.
create table if not exists public.impresoras (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  nombre      text not null,
  config      jsonb not null,
  creado_en   timestamptz not null default now()
);
create index if not exists impresoras_idx on public.impresoras (empresa_id, nombre);

alter table public.impresoras enable row level security;
drop policy if exists "por_empresa" on public.impresoras;
create policy "por_empresa" on public.impresoras as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()))
  with check (empresa_id = (select public.empresa_actual()));
drop policy if exists "ver_impresoras" on public.impresoras;
create policy "ver_impresoras" on public.impresoras for select to authenticated
  using ((select public.mi_rol()) is not null);
drop policy if exists "admin_impresoras" on public.impresoras;
create policy "admin_impresoras" on public.impresoras for all to authenticated
  using ((select public.mi_rol()) = 'admin')
  with check ((select public.mi_rol()) = 'admin');
