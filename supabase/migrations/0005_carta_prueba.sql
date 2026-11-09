-- Carta de prueba (opcional): grupos y productos típicos
insert into public.grupos_productos (nombre, color, orden) values
  ('Menú del día', '#E9DFC9', 1), ('Pintxos', '#F7C9A6', 2), ('Raciones', '#F2D59A', 3),
  ('Carnes', '#E8B8A8', 4), ('Bebidas', '#BFD8E8', 5), ('Postres y cafés', '#D9CFE6', 6);

with g as (select id, nombre from public.grupos_productos),
     a as (select id, nombre from public.areas_preparacion)
insert into public.productos (grupo_id, area_id, nombre, precio_venta, precio_compra, alergenos)
select g.id, a.id, p.nombre, p.pv, p.pc, p.al
from (values
  ('Menú del día', 'Cocina', 'Menú del día', 14.50, 5.00, '{gluten}'::text[]),
  ('Pintxos', 'Barra', 'Pintxo de tortilla', 2.80, 0.70, '{huevo}'),
  ('Pintxos', 'Barra', 'Gilda', 2.20, 0.60, '{pescado,sulfitos}'),
  ('Pintxos', 'Cocina', 'Croqueta de jamón', 1.80, 0.40, '{gluten,lacteos,huevo}'),
  ('Raciones', 'Cocina', 'Ensalada de bonito', 11.50, 3.50, '{pescado,huevo}'),
  ('Raciones', 'Cocina', 'Pimientos de Gernika', 7.80, 2.00, '{}'),
  ('Raciones', 'Cocina', 'Rabas', 10.50, 3.20, '{gluten,moluscos}'),
  ('Carnes', 'Cocina', 'Txuleta 1 kg', 48.00, 22.00, '{}'),
  ('Carnes', 'Cocina', 'Solomillo al Idiazabal', 22.50, 8.50, '{lacteos}'),
  ('Carnes', 'Cocina', 'Carrilleras al vino', 16.90, 5.50, '{sulfitos}'),
  ('Bebidas', 'Barra', 'Txakoli Getariako', 3.20, 0.90, '{sulfitos}'),
  ('Bebidas', 'Barra', 'Caña', 2.20, 0.50, '{gluten}'),
  ('Bebidas', 'Barra', 'Agua mineral 1 l', 2.80, 0.40, '{}'),
  ('Bebidas', 'Barra', 'Sidra natural', 3.50, 1.00, '{sulfitos}'),
  ('Postres y cafés', 'Barra', 'Café con leche', 1.80, 0.30, '{lacteos}'),
  ('Postres y cafés', 'Cocina', 'Tarta de queso', 5.70, 1.60, '{lacteos,huevo,gluten}')
) as p(grupo, area, nombre, pv, pc, al)
join g on g.nombre = p.grupo
join a on a.nombre = p.area;
