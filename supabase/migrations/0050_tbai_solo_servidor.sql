-- 0050 · TicketBAI: solo se firma y se envía lo que el servidor guarda (informe de seguridad run-2,
-- pistas 1, 7, 8, 15 y 16).
--  · Las facturas ya no se insertan desde la app: las guarda la función "ticketbai" (acción
--    registrar) después de comprobar que el fichero, la fila, la cadena, la numeración y el pedido
--    cuadran, y de firmarlo (o de comprobar la firma del equipo). El administrador solo puede
--    insertar facturas de legado (importadas).
--  · El estado de envío (estado_envio, respuesta_envio, envio_intento) lo escribe solo el servidor
--    que envía (función "ticketbai" con el puente). Nadie lo cambia desde la app.
--  · tbai_ultima_factura devuelve solo lo que hace falta para encadenar (id, serie, número, fecha y
--    firma) y no la ve la cocina.
--  · Anulaciones y subsanaciones se leen con las mismas reglas que su factura.
-- ORDEN: 1) la función "ticketbai" y el puente de Netlify, 2) la app nueva en todos los equipos,
-- 3) esta migración. Con la app antigua no se podrían emitir facturas.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Facturas: sin inserciones ni cambios de estado desde la app
-- =====================================================================
drop policy if exists "camarero_emitir_facturas" on public.facturas;
drop policy if exists "emitir_facturas" on public.facturas;
create policy "emitir_facturas" on public.facturas for insert to authenticated
  with check ((select public.mi_rol()) = 'admin' and legado);
drop policy if exists "camarero_estado_facturas" on public.facturas;
drop policy if exists "estado_facturas" on public.facturas;

-- El estado de envío de anulaciones y subsanaciones tampoco lo escribe la app (el admin sí las crea)
create or replace function public.estado_envio_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_user <> 'authenticated' then
    return new;
  end if;
  if tg_op = 'INSERT' then
    -- Cada campo se lee en su propio "if": NEW de otra tabla no tiene esas columnas
    if tg_table_name = 'facturas' then
      if new.legado then
        return new;   -- facturas antiguas importadas por el administrador
      end if;
    end if;
    new.estado_envio := 'pendiente';
    new.respuesta_envio := null;
    if tg_table_name <> 'tbai_subsanaciones' then
      new.envio_intento := null;
    end if;
    return new;
  end if;
  if new.estado_envio is distinct from old.estado_envio or new.respuesta_envio is distinct from old.respuesta_envio then
    raise exception 'El estado del envío a Hacienda solo lo cambia el servidor que envía';
  end if;
  return new;
end $$;
drop trigger if exists estado_envio_servidor on public.tbai_anulaciones;
create trigger estado_envio_servidor before insert or update on public.tbai_anulaciones
for each row execute function public.estado_envio_servidor();
drop trigger if exists estado_envio_servidor on public.tbai_subsanaciones;
create trigger estado_envio_servidor before insert or update on public.tbai_subsanaciones
for each row execute function public.estado_envio_servidor();
drop trigger if exists estado_envio_servidor on public.facturas;
create trigger estado_envio_servidor before insert or update on public.facturas
for each row execute function public.estado_envio_servidor();

-- Reclamar el envío lo hace ahora el servidor (acción preparar_envio)
revoke execute on function public.tbai_reclamar_envio(text, uuid) from public, anon, authenticated;

-- =====================================================================
-- 2 · Última factura de la cadena: solo lo necesario para encadenar
-- =====================================================================
drop function if exists public.tbai_ultima_factura(text);
create function public.tbai_ultima_factura(p_cadena text)
returns table (id uuid, serie text, numero int, fecha timestamptz, firma text)
language sql stable
security definer
set search_path = ''
as $$
  select f.id, f.serie, f.numero, f.fecha, f.firma
    from public.facturas f
   where f.cadena = p_cadena
     and f.empresa_id = (select public.empresa_actual())
     and (select public.mi_rol()) in ('admin', 'camarero')
     and not exists (select 1 from public.facturas g where g.anterior_id = f.id and g.empresa_id = f.empresa_id)
   order by f.legado, f.fecha desc, f.creado_en desc
   limit 1
$$;
revoke all on function public.tbai_ultima_factura(text) from public, anon;
grant execute on function public.tbai_ultima_factura(text) to authenticated;

-- =====================================================================
-- 3 · Anulaciones y subsanaciones: las ve quien ve su factura
-- =====================================================================
-- La consulta de la política corre con los permisos de quien lee: se aplican las reglas de facturas
drop policy if exists "leer_anulaciones" on public.tbai_anulaciones;
create policy "leer_anulaciones" on public.tbai_anulaciones for select to authenticated
  using (exists (select 1 from public.facturas f where f.id = factura_id));
drop policy if exists "leer_subsanaciones" on public.tbai_subsanaciones;
create policy "leer_subsanaciones" on public.tbai_subsanaciones for select to authenticated
  using (exists (select 1 from public.facturas f where f.id = factura_id));

-- =====================================================================
-- 4 · Para revisar (no cambia nada): facturas cuya cadena no cuadra con la anterior
-- =====================================================================
-- select f.empresa_id, f.serie, f.numero, f.fecha, a.serie as ant_serie, a.numero as ant_numero
--   from public.facturas f join public.facturas a on a.id = f.anterior_id
--  where not f.legado
--    and (f.anterior_serie is distinct from a.serie or f.anterior_numero is distinct from a.numero
--         or f.anterior_firma100 is distinct from left(a.firma, 100) or f.fecha < a.fecha
--         or f.fecha > f.creado_en + interval '5 minutes');
