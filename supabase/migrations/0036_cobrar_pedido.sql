-- 0036 · El cobro se guarda de una vez: pagos, pedido «pagado» y mesa libre van en la MISMA
-- transacción. Antes eran tres escrituras sueltas: si fallaba una a medias, al reintentar se
-- repetían los pagos (la caja esperaba el doble) o quedaba un pedido pagado sin pagos.
-- Si el pedido ya está pagado (reintento), no hace nada. No admite cobrar en un turno cerrado.
-- Corre con los permisos de quien cobra (las reglas de pagos, pedidos y mesas siguen mandando).
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- p_pagos: [{metodo, importe, pago_con?, vuelto?}, …]
-- Devuelve {ok: true, repetido: true|false}.
create or replace function public.cobrar_pedido(p_pedido uuid, p_turno uuid, p_pagos jsonb,
                                                p_cliente uuid default null, p_mesa uuid default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_estado text;
begin
  select p.estado into v_estado from public.pedidos p where p.id = p_pedido for update;
  if v_estado is null then raise exception 'Pedido no encontrado'; end if;
  if v_estado = 'pagado' then
    return jsonb_build_object('ok', true, 'repetido', true); -- un intento anterior ya lo cobró
  end if;
  if v_estado = 'anulado' then raise exception 'Este pedido está anulado'; end if;
  if p_pagos is null or jsonb_typeof(p_pagos) <> 'array' or jsonb_array_length(p_pagos) = 0 then
    raise exception 'Falta la forma de pago';
  end if;
  if not exists (select 1 from public.turnos_caja t where t.id = p_turno and t.estado = 'abierto') then
    raise exception 'La caja está cerrada: ábrela para cobrar';
  end if;

  insert into public.pagos (pedido_id, turno_id, metodo, importe, pago_con, vuelto)
  select p_pedido, p_turno, x->>'metodo', (x->>'importe')::numeric,
         (x->>'pago_con')::numeric, (x->>'vuelto')::numeric
    from jsonb_array_elements(p_pagos) x;

  update public.pedidos set
    estado = 'pagado',
    pagado_en = now(),
    turno_id = p_turno,
    cliente_id = coalesce(p_cliente, cliente_id)
  where id = p_pedido;

  if p_mesa is not null then
    update public.mesas set disponibilidad = 'libre' where id = p_mesa;
  end if;
  return jsonb_build_object('ok', true, 'repetido', false);
end $$;
revoke all on function public.cobrar_pedido(uuid, uuid, jsonb, uuid, uuid) from public, anon;
grant execute on function public.cobrar_pedido(uuid, uuid, jsonb, uuid, uuid) to authenticated;
