-- 0047 · Fuera la carta pública por QR (27/11/2026).
-- La carta web (/carta/?c=…) enseñaba a cualquiera las fotos de los productos, y la dirección de
-- cada foto llevaba el id del bar: con ese id la pantalla de entrada enseña quién trabaja aquí.
-- Ahora:
--  · No existe la función carta_publica: sin sesión no se puede leer nada de la carta.
--  · empresa.codigo_carta se queda, pero ya no lo usa nada (no se borra).
--  · El bucket de fotos 'productos' pasa a privado: solo ven las fotos los usuarios con sesión
--    del mismo bar (carpeta "<id del bar>/…"). La app las pide con una dirección firmada.
--    Las fotos antiguas guardadas fuera de una carpeta de bar dejan de verse: hay que volver a
--    subirlas desde Carta › producto › Cambiar imagen.
-- Ejecutar DESPUÉS de instalar la app nueva en todos los equipos (la antigua carga las fotos por
-- su dirección pública y dejaría de verlas). Ejecutar entero en el SQL Editor. Se puede ejecutar
-- más de una vez.

-- 1 · Carta pública
do $$
begin
  if to_regprocedure('public.carta_publica(uuid)') is not null then
    revoke all on function public.carta_publica(uuid) from public, anon, authenticated;
  end if;
end $$;
drop function if exists public.carta_publica(uuid);

comment on column public.empresa.codigo_carta is
  'Sin uso desde la 0047 (se quitó la carta pública por QR). Se conserva por si acaso.';

-- 2 · Fotos de productos: bucket privado
update storage.buckets set public = false where id = 'productos';

-- Leer: cualquier usuario con sesión del bar, solo su carpeta (es lo que permite firmar la dirección).
-- Subir, cambiar y borrar siguen como en la 0041 (solo el administrador, en la carpeta de su bar).
drop policy if exists "productos_img_leer" on storage.objects;
create policy "productos_img_leer" on storage.objects for select to authenticated
  using (bucket_id = 'productos' and (storage.foldername(name))[1] = (select public.empresa_actual())::text);
