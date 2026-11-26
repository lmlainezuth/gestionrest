-- 0033 · Control en Barra: queda apuntado cada producto que se quita de una venta ANTES de cobrarla
-- (quién, qué, cuánto valía y cuándo). Sale en el panel del dueño con las demás anulaciones.
-- No frena al camarero: solo deja rastro. Necesita la 0019.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

alter table public.registro_anulaciones drop constraint if exists registro_anulaciones_tipo_check;
alter table public.registro_anulaciones add constraint registro_anulaciones_tipo_check
  check (tipo in ('linea_anulada','linea_borrada','pedido_anulado','venta_anulada',
                  'factura_anulada','devolucion','quitado_antes_cobrar'));

-- La tabla no admite escrituras desde la app: se apunta solo por esta función, con el usuario real.
-- p_momento: cuándo se quitó (si se apuntó sin internet y se sube después).
create or replace function public.registrar_quitado(p_descripcion text, p_cantidad numeric, p_importe numeric,
                                                    p_momento timestamptz default null, p_donde text default 'Barra')
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select public.mi_rol()) is null then
    raise exception 'Sin permiso';
  end if;
  if coalesce(p_cantidad, 0) <= 0 or coalesce(p_importe, 0) < 0 then
    return;
  end if;
  insert into public.registro_anulaciones (empresa_id, momento, usuario_id, tipo, descripcion, cantidad, importe, mesa)
  values ((select public.empresa_actual()),
          -- no se admite una hora futura ni de hace más de 3 días
          case when p_momento is null or p_momento > now() or p_momento < now() - interval '3 days' then now() else p_momento end,
          auth.uid(), 'quitado_antes_cobrar', left(coalesce(p_descripcion, ''), 200), p_cantidad, p_importe,
          left(coalesce(p_donde, 'Barra'), 60));
end $$;
revoke all on function public.registrar_quitado(text, numeric, numeric, timestamptz, text) from public, anon;
grant execute on function public.registrar_quitado(text, numeric, numeric, timestamptz, text) to authenticated;
