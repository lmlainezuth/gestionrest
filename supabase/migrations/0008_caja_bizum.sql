-- Bizum como forma de pago
alter table public.pagos drop constraint pagos_metodo_check;
alter table public.pagos add constraint pagos_metodo_check
  check (metodo in ('efectivo','tarjeta','bizum','credito'));

-- Conceptos de gasto habituales
insert into public.conceptos_gasto (nombre) values
  ('Proveedor'), ('Cambio / monedas'), ('Limpieza'), ('Reparaciones'), ('Otros');
