-- Anulación de platos ya enviados (cocina recibe el aviso)
alter table public.pedido_detalle
  add column anulado_en timestamptz,
  add column anulado_motivo text;

-- Factura completa: dirección del cliente
alter table public.facturas add column cliente_direccion text;

-- Pedidos unidos a otra mesa
alter table public.pedidos drop constraint if exists pedidos_estado_check;
alter table public.pedidos add constraint pedidos_estado_check
  check (estado in ('abierto','precuenta','pagado','anulado','unido'));
