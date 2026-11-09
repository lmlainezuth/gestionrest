-- 0018 · Cuadre de caja ciego + cuadrante de turnos
-- Ejecutar entero en el SQL Editor (después de 0017). Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Cuadre ciego
-- El que cierra cuenta el cajón SIN ver lo esperado. El esperado lo calcula el servidor
-- en el momento del cierre y queda guardado. Un turno cerrado ya no se modifica.
-- =====================================================================
alter table public.turnos_caja add column if not exists conteo             jsonb;          -- {"50": 2, "0.5": 7, ...}
alter table public.turnos_caja add column if not exists tarjeta_calculado  numeric(12,2);
alter table public.turnos_caja add column if not exists tarjeta_real       numeric(12,2); -- cierre del datáfono
alter table public.turnos_caja add column if not exists tarjeta_diferencia numeric(12,2);
alter table public.turnos_caja add column if not exists cerrado_por        uuid references public.perfiles(id);
alter table public.turnos_caja add column if not exists nota               text;

-- El camarero también abre caja y apunta ingresos/gastos (solo a su nombre)
drop policy if exists "camarero_abrir_turno" on public.turnos_caja;
create policy "camarero_abrir_turno" on public.turnos_caja for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero' and usuario_id = (select auth.uid()) and estado = 'abierto');
drop policy if exists "camarero_mov_caja" on public.movimientos_caja;
create policy "camarero_mov_caja" on public.movimientos_caja for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero' and usuario_id = (select auth.uid())
              and exists (select 1 from public.turnos_caja t where t.id = turno_id and t.estado = 'abierto'));
drop policy if exists "camarero_ver_mov_caja" on public.movimientos_caja;
create policy "camarero_ver_mov_caja" on public.movimientos_caja for select to authenticated
  using ((select public.mi_rol()) = 'camarero');

-- Cerrar solo con la función de cierre; cerrado = intocable
create or replace function public.turno_caja_proteger()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.estado = 'cerrado' then
    if to_jsonb(new) = to_jsonb(old) then return new; end if;   -- restaurar copia: fila idéntica
    raise exception 'Un turno de caja cerrado no se puede modificar';
  end if;
  if new.estado = 'cerrado' and coalesce(current_setting('gestionrest.cierre_ciego', true), '') <> '1' then
    raise exception 'La caja se cierra con el cuadre (Cerrar caja)';
  end if;
  return new;
end $$;
drop trigger if exists turno_caja_proteger on public.turnos_caja;
create trigger turno_caja_proteger before update on public.turnos_caja
for each row execute function public.turno_caja_proteger();

create or replace function public.cerrar_caja_ciego(p_turno uuid, p_efectivo numeric, p_conteo jsonb default null,
                                                   p_tarjeta numeric default null, p_nota text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.turnos_caja;
  v_esp numeric;
  v_tar numeric;
begin
  if (select public.mi_rol()) not in ('admin','camarero') then
    raise exception 'No puedes cerrar la caja';
  end if;
  select * into t from public.turnos_caja
   where id = p_turno and empresa_id = (select public.empresa_actual()) for update;
  if t.id is null then raise exception 'Turno no encontrado'; end if;
  if t.estado <> 'abierto' then raise exception 'Este turno ya está cerrado'; end if;
  if p_efectivo is null or p_efectivo < 0 then raise exception 'Importe contado no válido'; end if;

  select t.efectivo_inicial
         + coalesce((select sum(p.importe) from public.pagos p where p.turno_id = t.id and p.metodo = 'efectivo'), 0)
         + coalesce((select sum(case m.tipo when 'ingreso' then m.importe else -m.importe end)
                       from public.movimientos_caja m where m.turno_id = t.id), 0)
    into v_esp;
  select coalesce(sum(p.importe), 0) into v_tar from public.pagos p where p.turno_id = t.id and p.metodo = 'tarjeta';

  perform set_config('gestionrest.cierre_ciego', '1', true);
  update public.turnos_caja set
    estado = 'cerrado',
    cerrado_en = now(),
    cerrado_por = auth.uid(),
    efectivo_calculado = v_esp,
    efectivo_real = p_efectivo,
    diferencia = p_efectivo - v_esp,
    conteo = p_conteo,
    tarjeta_calculado = v_tar,
    tarjeta_real = p_tarjeta,
    tarjeta_diferencia = case when p_tarjeta is null then null else p_tarjeta - v_tar end,
    nota = nullif(trim(p_nota), '')
  where id = t.id;
  perform set_config('gestionrest.cierre_ciego', '', true);

  -- El camarero no ve el resultado (si no, aprendería cuánto "sobra"); el encargado sí
  if (select public.mi_rol()) <> 'admin' then
    return jsonb_build_object('ok', true);
  end if;
  return jsonb_build_object('ok', true, 'esperado', v_esp, 'contado', p_efectivo, 'diferencia', p_efectivo - v_esp,
                            'tarjeta_esperado', v_tar, 'tarjeta_contado', p_tarjeta,
                            'tarjeta_diferencia', case when p_tarjeta is null then null else p_tarjeta - v_tar end);
end $$;
grant execute on function public.cerrar_caja_ciego(uuid, numeric, jsonb, numeric, text) to authenticated;

-- =====================================================================
-- 2 · Cuadrante: horario planificado de cada empleado
-- Un día puede tener varios tramos (turno partido). Si fin < inicio, acaba al día siguiente.
-- =====================================================================
create table if not exists public.cuadrante (
  id          uuid primary key default gen_random_uuid(),
  empresa_id  uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  usuario_id  uuid not null references public.perfiles(id) on delete cascade,
  fecha       date not null,
  inicio      time not null,
  fin         time not null,
  nota        text,
  creado_en   timestamptz not null default now(),
  check (inicio <> fin)
);
create index if not exists cuadrante_empresa_fecha_idx on public.cuadrante (empresa_id, fecha);
create index if not exists cuadrante_usuario_fecha_idx on public.cuadrante (usuario_id, fecha);

alter table public.cuadrante enable row level security;
drop policy if exists "por_empresa" on public.cuadrante;
create policy "por_empresa" on public.cuadrante as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()))
  with check (empresa_id = (select public.empresa_actual()));
drop policy if exists "admin_cuadrante" on public.cuadrante;
create policy "admin_cuadrante" on public.cuadrante for all to authenticated
  using ((select public.mi_rol()) = 'admin') with check ((select public.mi_rol()) = 'admin');
drop policy if exists "ver_mi_cuadrante" on public.cuadrante;
create policy "ver_mi_cuadrante" on public.cuadrante for select to authenticated
  using (usuario_id = (select auth.uid()));

-- Al fichar, el empleado ve también sus turnos de esta semana y la siguiente
create or replace function public.fichaje_estado(p_empresa uuid, p_usuario uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text := public.fichaje_comprobar(p_empresa, p_usuario, p_pin);
  v_lunes date := date_trunc('week', now() at time zone 'Europe/Madrid')::date;
begin
  if v_nombre is null then
    return jsonb_build_object('error', 'PIN incorrecto');
  end if;
  return jsonb_build_object(
    'nombre', v_nombre,
    'registros', coalesce((
      select jsonb_agg(jsonb_build_object('tipo', f.tipo, 'momento', f.momento) order by f.momento)
        from public.fichajes_vigentes f
       where f.empresa_id = p_empresa and f.usuario_id = p_usuario
         and f.momento >= (v_lunes::timestamp at time zone 'Europe/Madrid')
    ), '[]'::jsonb),
    'turnos', coalesce((
      select jsonb_agg(jsonb_build_object('fecha', c.fecha, 'inicio', c.inicio, 'fin', c.fin) order by c.fecha, c.inicio)
        from public.cuadrante c
       where c.empresa_id = p_empresa and c.usuario_id = p_usuario
         and c.fecha >= (now() at time zone 'Europe/Madrid')::date and c.fecha < v_lunes + 14
    ), '[]'::jsonb));
end $$;
grant execute on function public.fichaje_estado(uuid, uuid, text) to anon, authenticated;
