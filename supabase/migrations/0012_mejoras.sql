-- Modificadores disponibles para cada producto (extra de queso +1 €…)
create table public.producto_modificadores (
  producto_id    uuid not null references public.productos(id) on delete cascade,
  modificador_id uuid not null references public.modificadores(id) on delete cascade,
  primary key (producto_id, modificador_id)
);
create index on public.producto_modificadores (modificador_id);
alter table public.producto_modificadores enable row level security;
create policy "leer_prod_mod" on public.producto_modificadores for select to authenticated
  using ((select public.mi_rol()) is not null);
create policy "admin_prod_mod" on public.producto_modificadores for all to authenticated
  using ((select public.mi_rol()) = 'admin')
  with check ((select public.mi_rol()) = 'admin');

-- Permisos por usuario: null = todos los de su rol; si no, solo los de la lista
alter table public.perfiles add column permisos text[];

-- Imágenes de productos (Storage público; solo el admin sube y borra)
insert into storage.buckets (id, name, public) values ('productos', 'productos', true)
  on conflict (id) do nothing;
create policy "productos_img_leer" on storage.objects for select
  using (bucket_id = 'productos');
create policy "productos_img_subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'productos' and (select public.mi_rol()) = 'admin');
create policy "productos_img_cambiar" on storage.objects for update to authenticated
  using (bucket_id = 'productos' and (select public.mi_rol()) = 'admin');
create policy "productos_img_borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'productos' and (select public.mi_rol()) = 'admin');
