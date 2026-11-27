-- 0038 · Entrada con PIN: el correo interno solo se da con el PIN correcto (auditoría 27/11/2026).
-- Hasta ahora equipo_login daba a cualquiera, con el id de la empresa, el correo interno de todo el
-- equipo, y con él se podía probar PIN tras PIN directamente contra Supabase Auth (la contraseña es
-- 'GRpin-<PIN>-<parte del correo>'). Ahora la app pide el correo a correo_pin, que comprueba el PIN
-- en la base con el mismo límite que fichar (5 fallos en 15 minutos por usuario), y luego entra.
-- Sin el correo (12 caracteres aleatorios) no hay nada que probar contra Auth.
-- ORDEN: 1) esta migración, 2) la app nueva en todos los equipos, 3) la 0039 (quita el correo de
-- equipo_login). Esta no rompe nada: las apps antiguas siguen usando el correo de equipo_login.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

create or replace function public.correo_pin(p_empresa uuid, p_usuario uuid, p_pin text)
returns text   -- correo interno, o null si el PIN no es correcto (el fallo queda apuntado)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_correo text;
begin
  -- Mismo control que fichar: pertenencia activa al bar, PIN y límite de fallos
  if public.fichaje_comprobar(p_empresa, p_usuario, p_pin) is null then
    return null;
  end if;
  select p.correo into v_correo from public.perfiles p where p.id = p_usuario;
  return v_correo;
end $$;
revoke all on function public.correo_pin(uuid, uuid, text) from public;
grant execute on function public.correo_pin(uuid, uuid, text) to anon, authenticated;
