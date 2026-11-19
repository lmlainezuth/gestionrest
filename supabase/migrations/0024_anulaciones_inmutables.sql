-- 0024 · TicketBAI: el registro de anulaciones no se borra ni se modifica (igual que las facturas).
-- Solo pueden cambiar el estado del envío, la respuesta de Hacienda y la marca de intento de envío.
-- Excepción: una anulación que Hacienda rechazó (estado 'error') se puede volver a emitir.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

create or replace function public.anulacion_inmutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Una anulación no se puede borrar';
  end if;
  if old.estado_envio = 'error' then
    return new; -- rechazada por Hacienda: se puede volver a emitir
  end if;
  if (to_jsonb(new) - 'estado_envio' - 'respuesta_envio' - 'envio_intento')
     is distinct from (to_jsonb(old) - 'estado_envio' - 'respuesta_envio' - 'envio_intento') then
    raise exception 'Una anulación emitida no se puede modificar';
  end if;
  return new;
end $$;

drop trigger if exists anulaciones_inmutables on public.tbai_anulaciones;
create trigger anulaciones_inmutables
before update or delete on public.tbai_anulaciones
for each row execute function public.anulacion_inmutable();
