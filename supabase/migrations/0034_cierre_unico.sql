-- 0034 · Un solo papel de cierre, igual para todos: quien cierra (camarero incluido) recibe el
-- resultado completo (ventas, esperado, contado, diferencia, quitado antes de cobrar) para imprimirlo
-- y entregarlo con el dinero. El recuento sigue siendo a ciegas: mientras cuenta no ve lo esperado,
-- y el resultado solo se devuelve cuando el recuento ya está guardado y no se puede cambiar.
-- Necesita la 0021 y la 0019 (mejor también la 0033). Ejecutar entero en el SQL Editor.
-- Se puede ejecutar más de una vez.

create or replace function public.cerrar_caja_ciego(p_turno uuid, p_efectivo numeric, p_conteo jsonb default null,
                                                   p_tarjeta numeric default null, p_nota text default null,
                                                   p_fondo numeric default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.turnos_caja;
  v_esp numeric;
  v_tar numeric;
  v_ing numeric;
  v_gas numeric;
  v_q_uds numeric;
  v_q_imp numeric;
begin
  if (select public.mi_rol()) not in ('admin','camarero') then
    raise exception 'No puedes cerrar la caja';
  end if;
  select * into t from public.turnos_caja
   where id = p_turno and empresa_id = (select public.empresa_actual()) for update;
  if t.id is null then raise exception 'Turno no encontrado'; end if;
  if t.estado <> 'abierto' then raise exception 'Este turno ya está cerrado'; end if;
  if p_efectivo is null or p_efectivo < 0 then raise exception 'Importe contado no válido'; end if;
  if p_fondo is not null and (p_fondo < 0 or p_fondo > p_efectivo) then
    raise exception 'El fondo que se deja no puede ser mayor que lo contado';
  end if;

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
    nota = nullif(concat_ws(' · ', t.nota, nullif(trim(p_nota), '')), ''),  -- conserva la nota de apertura
    fondo_siguiente = p_fondo
  where id = t.id;
  perform set_config('gestionrest.cierre_ciego', '', true);

  -- El recuento ya está guardado y no se puede cambiar: ahora sí se devuelve el resultado a quien
  -- cierra (camarero incluido), con lo necesario para imprimir el cierre completo.
  select coalesce(sum(m.importe) filter (where m.tipo = 'ingreso'), 0),
         coalesce(sum(m.importe) filter (where m.tipo = 'gasto'), 0)
    into v_ing, v_gas from public.movimientos_caja m where m.turno_id = t.id;
  select coalesce(sum(a.cantidad), 0), coalesce(sum(a.importe), 0) into v_q_uds, v_q_imp
    from public.registro_anulaciones a
   where a.empresa_id = t.empresa_id and a.tipo = 'quitado_antes_cobrar' and a.momento >= t.abierto_en;
  return jsonb_build_object('ok', true, 'esperado', v_esp, 'contado', p_efectivo, 'diferencia', p_efectivo - v_esp,
                            'tarjeta_esperado', v_tar, 'tarjeta_contado', p_tarjeta,
                            'tarjeta_diferencia', case when p_tarjeta is null then null else p_tarjeta - v_tar end,
                            'ingresos', v_ing, 'gastos', v_gas,
                            'quitados_uds', v_q_uds, 'quitados_importe', v_q_imp);
end $$;
grant execute on function public.cerrar_caja_ciego(uuid, numeric, jsonb, numeric, text, numeric) to authenticated;
