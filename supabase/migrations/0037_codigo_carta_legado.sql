-- 0037 · Seguridad antes del registro TicketBAI (revisión del 26/11/2026).
-- 1) La carta pública deja de abrirse con el id de la empresa. Ese id iba en el QR que ve
--    cualquier cliente, y con él la pantalla de entrada (equipo_login) da el nombre, el rol y
--    el correo interno de todo el equipo: solo faltaba adivinar el PIN. Ahora la carta tiene
--    su propio código (empresa.codigo_carta) y el id de la empresa ya no sale del bar.
-- 2) Un camarero no puede guardar una factura marcada como «legado» (se saltaba la
--    comprobación de serie en producción y el arranque de la cadena).
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.
-- DESPUÉS de ejecutarlo hay que publicar la web (carta) y usar la app con el QR nuevo:
-- los enlaces de carta antiguos (?e=<id de la empresa>) dejan de funcionar.

-- =====================================================================
-- 1 · Código propio de la carta
-- =====================================================================
alter table public.empresa add column if not exists codigo_carta uuid not null default gen_random_uuid();
create unique index if not exists empresa_codigo_carta_key on public.empresa (codigo_carta);

-- Cambia el nombre del parámetro (p_empresa → p_codigo): hay que borrarla y volver a crearla
drop function if exists public.carta_publica(uuid);
create function public.carta_publica(p_codigo uuid)
returns jsonb
language sql stable security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'nombre', e.nombre,
    'grupos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'nombre', g.nombre,
               'color', g.color,
               'productos', (
                 select coalesce(jsonb_agg(jsonb_build_object(
                          'nombre', p.nombre, 'precio', p.precio_venta,
                          'alergenos', p.alergenos, 'imagen', p.imagen_url) order by p.nombre), '[]'::jsonb)
                   from public.productos p
                  where p.grupo_id = g.id and p.activo))
             order by g.orden, g.nombre)
        from public.grupos_productos g
       where g.empresa_id = e.id and g.activo
         and exists (select 1 from public.productos p where p.grupo_id = g.id and p.activo)
    ), '[]'::jsonb))
  from public.empresa e where e.codigo_carta = p_codigo
$$;
revoke all on function public.carta_publica(uuid) from public;
grant execute on function public.carta_publica(uuid) to anon, authenticated;

-- =====================================================================
-- 2 · «legado» solo lo pone un administrador (o los scripts del SQL Editor)
-- =====================================================================
drop policy if exists "camarero_emitir_facturas" on public.facturas;
create policy "camarero_emitir_facturas" on public.facturas for insert to authenticated
  with check ((select public.mi_rol()) = 'camarero' and not legado);
