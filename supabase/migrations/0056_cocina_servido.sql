-- 0056 · Que la pantalla de Cocina no acumule platos para siempre.
--  1. Ajuste por bar «Usa pantalla de cocina» (empresa.usa_cocina, lo cambia el administrador en
--     Ajustes › Empresa). Apagado: todo plato nuevo se guarda ya como servido.
--  2. Al cobrar una cuenta, sus platos pendientes, en preparación o listos pasan a servido. También
--     un plato que llegue a una cuenta ya cobrada (ventas sin internet que se suben después).
--  3. Al cerrar un turno de caja, los platos del bar pedidos desde que se abrió ese turno y que sigan
--     en cocina pasan a servido, también los de cuentas que sigan abiertas (fin del servicio).
--  4. Limpieza única de lo que ya está atascado (al final).
-- Pasar a «servido» NO es una anulación: no se apunta en registro_anulaciones (solo lo hace el paso a
-- «anulado») ni en eventos_seguridad.
--
-- Antes de ejecutarla, si quieres saber cuántos platos cambiará la limpieza:
--   select count(*) from public.pedido_detalle d
--    where d.estado_cocina in ('pendiente', 'preparando', 'listo')
--      and (d.creado_en < now() - interval '24 hours'
--           or exists (select 1 from public.pedidos p where p.id = d.pedido_id and p.estado in ('pagado', 'anulado', 'unido')));
--
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Ajuste por bar
-- =====================================================================
alter table public.empresa add column if not exists usa_cocina boolean not null default true;

-- Plato nuevo en un bar sin pantalla de cocina, o en una cuenta ya cobrada: ya servido
create or replace function public.linea_sin_cocina()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.estado_cocina in ('pendiente', 'preparando', 'listo')
     and (exists (select 1 from public.empresa e where e.id = new.empresa_id and not e.usa_cocina)
          or exists (select 1 from public.pedidos p where p.id = new.pedido_id and p.estado = 'pagado')) then
    new.estado_cocina := 'servido';
  end if;
  return new;
end $$;
drop trigger if exists linea_sin_cocina on public.pedido_detalle;
create trigger linea_sin_cocina before insert on public.pedido_detalle
for each row execute function public.linea_sin_cocina();

-- =====================================================================
-- 2 · Al cobrar
-- =====================================================================
create or replace function public.servir_al_cobrar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.estado = 'pagado' and old.estado is distinct from 'pagado' then
    update public.pedido_detalle
       set estado_cocina = 'servido'
     where pedido_id = new.id and empresa_id = new.empresa_id
       and estado_cocina in ('pendiente', 'preparando', 'listo');
  end if;
  return null;
end $$;
drop trigger if exists servir_al_cobrar on public.pedidos;
create trigger servir_al_cobrar after update of estado on public.pedidos
for each row execute function public.servir_al_cobrar();

-- =====================================================================
-- 3 · Al cerrar caja
-- =====================================================================
create or replace function public.servir_al_cerrar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.estado = 'cerrado' and old.estado is distinct from 'cerrado' then
    update public.pedido_detalle
       set estado_cocina = 'servido'
     where empresa_id = new.empresa_id
       and estado_cocina in ('pendiente', 'preparando', 'listo')
       and creado_en >= new.abierto_en
       and creado_en <= coalesce(new.cerrado_en, now());
  end if;
  return null;
end $$;
drop trigger if exists servir_al_cerrar on public.turnos_caja;
create trigger servir_al_cerrar after update of estado on public.turnos_caja
for each row execute function public.servir_al_cerrar();

revoke all on function public.linea_sin_cocina() from public, anon, authenticated;
revoke all on function public.servir_al_cobrar() from public, anon, authenticated;
revoke all on function public.servir_al_cerrar() from public, anon, authenticated;

-- =====================================================================
-- 4 · Limpieza única de lo atascado: más de 24 horas, o de cuentas ya cobradas, anuladas o unidas
-- =====================================================================
do $$
declare
  n int;
begin
  update public.pedido_detalle d
     set estado_cocina = 'servido'
   where d.estado_cocina in ('pendiente', 'preparando', 'listo')
     and (d.creado_en < now() - interval '24 hours'
          or exists (select 1 from public.pedidos p where p.id = d.pedido_id and p.estado in ('pagado', 'anulado', 'unido')));
  get diagnostics n = row_count;
  raise notice 'Platos atascados en cocina pasados a servido: %', n;
end $$;
