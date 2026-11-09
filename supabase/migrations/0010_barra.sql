-- Venta en barra: pedidos sin mesa (cobro directo o cuenta con nombre)
alter table public.pedidos drop constraint if exists pedidos_tipo_check;
alter table public.pedidos drop constraint if exists pedidos_check;
alter table public.pedidos add constraint pedidos_tipo_check
  check (tipo in ('mesa','llevar','barra'));
alter table public.pedidos add constraint pedidos_mesa_check
  check (tipo in ('llevar','barra') or mesa_id is not null);

-- El camarero también cobra (en barra es lo normal)
create policy "camarero_ver_turnos" on public.turnos_caja for select to authenticated
  using ((select public.mi_rol()) = 'camarero');
create policy "camarero_pagos" on public.pagos for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero');
create policy "camarero_ver_pagos" on public.pagos for select to authenticated
  using ((select public.mi_rol()) = 'camarero');
create policy "camarero_ver_facturas" on public.facturas for select to authenticated
  using ((select public.mi_rol()) = 'camarero');
create policy "camarero_emitir_facturas" on public.facturas for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero');
create policy "camarero_estado_facturas" on public.facturas for update to authenticated
  using ((select public.mi_rol()) = 'camarero')
  with check ((select public.mi_rol()) = 'camarero');
