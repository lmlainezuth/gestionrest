-- 0025 · TicketBAI: subsanaciones enviadas por el servicio Zuzendu-alta (OF 16/2022).
-- Cuando Hacienda rechaza un fichero de alta, la factura y su fichero no se tocan: se envía un
-- fichero de subsanación con los datos corregidos, y aquí queda guardado con la respuesta.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

create table if not exists public.tbai_subsanaciones (
  id              uuid primary key default gen_random_uuid(),
  empresa_id      uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  factura_id      uuid not null references public.facturas(id),
  fecha           timestamptz not null default now(),
  accion          text not null default 'SUBSANAR' check (accion in ('SUBSANAR', 'MODIFICAR')),
  xml             text not null,
  estado_envio    text not null default 'pendiente' check (estado_envio in ('pendiente', 'enviada', 'error')),
  respuesta_envio text,
  creado_por      uuid default auth.uid() references public.perfiles(id)
);
create index if not exists tbai_subsanaciones_empresa_idx on public.tbai_subsanaciones (empresa_id);
create index if not exists tbai_subsanaciones_factura_idx on public.tbai_subsanaciones (factura_id);

alter table public.tbai_subsanaciones enable row level security;
drop policy if exists "leer_subsanaciones" on public.tbai_subsanaciones;
create policy "leer_subsanaciones" on public.tbai_subsanaciones for select to authenticated
  using ((select public.mi_rol()) is not null);
drop policy if exists "admin_subsanaciones" on public.tbai_subsanaciones;
create policy "admin_subsanaciones" on public.tbai_subsanaciones for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');
drop policy if exists "por_empresa" on public.tbai_subsanaciones;
create policy "por_empresa" on public.tbai_subsanaciones as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()))
  with check (empresa_id = (select public.empresa_actual()));

-- Un fichero de subsanación enviado no se borra ni se cambia: solo su estado y la respuesta
create or replace function public.subsanacion_inmutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Una subsanación no se puede borrar';
  end if;
  if (to_jsonb(new) - 'estado_envio' - 'respuesta_envio')
     is distinct from (to_jsonb(old) - 'estado_envio' - 'respuesta_envio') then
    raise exception 'Una subsanación enviada no se puede modificar';
  end if;
  return new;
end $$;

drop trigger if exists subsanaciones_inmutables on public.tbai_subsanaciones;
create trigger subsanaciones_inmutables
before update or delete on public.tbai_subsanaciones
for each row execute function public.subsanacion_inmutable();
