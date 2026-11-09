-- Orden de salida de cada plato: ya (bebidas), 1.º, 2.º o postre
alter table public.pedido_detalle
  add column curso text not null default '1'
  check (curso in ('ya','1','2','postre'));
