-- Datos de prueba: un salón con 6 mesas
with s as (
  insert into public.salones (nombre, orden) values ('Principal', 1)
  returning id
)
insert into public.mesas (salon_id, nombre)
select s.id, 'M' || n from s, generate_series(1, 6) as n;
