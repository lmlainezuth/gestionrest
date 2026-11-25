-- 0029 · Crear empresa con su titular: nombre del bar, razón social y NIF desde el principio.
-- Así la caja nace con su serie a nombre del titular real (no del NIF de relleno B00000000).
-- La licencia y el NIF del desarrollador no se guardan: los pone la app (son del programa).
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

drop function if exists public.crear_empresa(text, text);
drop function if exists public.crear_empresa(text, text, text);

create function public.crear_empresa(p_nombre text, p_nif text default 'B00000000', p_razon text default null)
returns uuid
language plpgsql security definer
set search_path = ''
as $$
declare
  v uuid;
  v_nif text := upper(trim(coalesce(p_nif, '')));
begin
  if public.mi_rol() is distinct from 'admin' then
    raise exception 'Solo un administrador puede crear empresas';
  end if;
  if coalesce(trim(p_nombre), '') = '' then
    raise exception 'Falta el nombre del bar';
  end if;
  if length(v_nif) <> 9 then
    raise exception 'El NIF del titular tiene que tener 9 caracteres';
  end if;
  insert into public.empresa (nombre, documento_fiscal) values (trim(p_nombre), v_nif) returning id into v;
  insert into public.empresa_usuarios (empresa_id, usuario_id, rol) values (v, auth.uid(), 'admin');
  insert into public.tbai_config (empresa_id, nif, razon_social)
  values (v, v_nif, coalesce(nullif(upper(trim(p_razon)), ''), trim(p_nombre)));
  insert into public.areas_preparacion (empresa_id, nombre) values (v, 'Cocina'), (v, 'Barra');
  insert into public.cajas (empresa_id, nombre) values (v, 'Caja principal');
  insert into public.conceptos_gasto (empresa_id, nombre) values
    (v, 'Proveedor'), (v, 'Cambio / monedas'), (v, 'Limpieza'), (v, 'Reparaciones'), (v, 'Otros');
  perform public.tbai_nueva_serie(v, 'caja', 'Caja principal');
  return v;
end $$;
revoke all on function public.crear_empresa(text, text, text) from public, anon;
grant execute on function public.crear_empresa(text, text, text) to authenticated;
