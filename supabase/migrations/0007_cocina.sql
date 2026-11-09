-- Platos retenidos hasta que el camarero los "marcha" (2.º y postre)
alter table public.pedido_detalle
  add column en_espera boolean not null default false;

-- El cocinero solo puede cambiar el estado del plato (no lo que se marcha)
create or replace function public.limitar_cocinero()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.mi_rol() = 'cocinero' and
     (new.pedido_id, new.producto_id, new.cantidad, new.precio_unitario,
      new.descripcion, new.nota, new.area_id, new.curso, new.en_espera)
     is distinct from
     (old.pedido_id, old.producto_id, old.cantidad, old.precio_unitario,
      old.descripcion, old.nota, old.area_id, old.curso, old.en_espera) then
    raise exception 'El cocinero solo puede cambiar el estado del plato';
  end if;
  return new;
end $$;

-- Tiempo real: la cocina recibe las comandas al momento
alter publication supabase_realtime add table public.pedido_detalle, public.pedidos;
