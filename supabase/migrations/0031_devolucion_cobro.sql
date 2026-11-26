-- 0031 · Al anular una factura o emitir una devolución, el dinero sale de la caja: se apunta un
-- pago en NEGATIVO en el turno abierto, con el mismo método del cobro. Así el efectivo esperado
-- (y el datáfono) del cierre bajan solos y la caja cuadra.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- Los pagos pueden ser negativos (devoluciones), nunca 0
alter table public.pagos drop constraint if exists pagos_importe_check;
alter table public.pagos add constraint pagos_importe_check check (importe <> 0);

-- El camarero sigue pudiendo cobrar, pero no apuntar devoluciones por su cuenta
drop policy if exists "camarero_pagos" on public.pagos;
create policy "camarero_pagos" on public.pagos for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero' and importe > 0);

-- p_factura: la factura ORIGINAL (la que se anula o de la que se devuelve algo).
-- p_importe: cuánto se devuelve; null = todo lo cobrado (anulación).
-- p_referencia: texto único de la operación ('ANUL T1-25', 'DEV T1R-3'); si ya existe, no repite.
-- Devuelve {ok, devuelto} o {ok:false, motivo: 'sin_cobro' | 'sin_turno'}.
create or replace function public.devolver_cobro(p_factura uuid, p_importe numeric default null,
                                                 p_referencia text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  f public.facturas;
  v_emp uuid := (select public.empresa_actual());
  v_turno uuid;
  v_resta numeric;
  v_total numeric := 0;
  v_parte numeric;
  r record;
begin
  if (select public.mi_rol()) <> 'admin' then
    raise exception 'Solo el administrador puede devolver un cobro';
  end if;
  select * into f from public.facturas where id = p_factura and empresa_id = v_emp;
  if f.id is null then raise exception 'Factura no encontrada'; end if;
  if f.pedido_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_cobro'); -- factura sin cobro en caja
  end if;
  if p_referencia is not null and exists (
       select 1 from public.pagos p where p.pedido_id = f.pedido_id and p.referencia = p_referencia) then
    return jsonb_build_object('ok', true, 'devuelto', 0); -- ya estaba apuntada
  end if;

  -- Turno abierto: el de la caja de la factura o, si no, cualquiera del bar
  select t.id into v_turno from public.turnos_caja t
   where t.empresa_id = v_emp and t.estado = 'abierto'
   order by (t.caja_id = f.caja_id) desc nulls last, t.abierto_en desc
   limit 1;
  if v_turno is null then
    return jsonb_build_object('ok', false, 'motivo', 'sin_turno');
  end if;

  -- Lo que queda cobrado de ese pedido por método (ya descontadas devoluciones anteriores).
  -- Devolución parcial de un cobro mixto: primero el efectivo.
  v_resta := p_importe;
  for r in
    select p.metodo, sum(p.importe) as neto from public.pagos p
     where p.pedido_id = f.pedido_id
     group by p.metodo having sum(p.importe) > 0
     order by (p.metodo = 'efectivo') desc, sum(p.importe) desc
  loop
    v_parte := case when v_resta is null then r.neto else least(r.neto, v_resta) end;
    if v_parte > 0 then
      insert into public.pagos (empresa_id, pedido_id, turno_id, metodo, importe, referencia)
      values (v_emp, f.pedido_id, v_turno, r.metodo, -v_parte, p_referencia);
      v_total := v_total + v_parte;
      if v_resta is not null then v_resta := v_resta - v_parte; end if;
    end if;
  end loop;

  if v_total = 0 then
    return jsonb_build_object('ok', false, 'motivo', 'sin_cobro');
  end if;
  return jsonb_build_object('ok', true, 'devuelto', v_total);
end $$;
revoke all on function public.devolver_cobro(uuid, numeric, text) from public, anon;
grant execute on function public.devolver_cobro(uuid, numeric, text) to authenticated;
