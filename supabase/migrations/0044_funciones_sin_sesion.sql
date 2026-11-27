-- 0044 · Sin sesión solo se pueden llamar las funciones públicas de verdad (auditoría 27/11/2026).
-- Postgres deja ejecutar cualquier función a todo el mundo (PUBLIC) salvo que se quite. Ahora:
--  · Sin sesión (anon): solo entrada con PIN (equipo_login, correo_pin), fichar y la carta pública.
--  · Con sesión (authenticated): las demás, como hasta ahora (cada una comprueba rol y bar).
--  · Nadie desde fuera: las internas (las usan otras funciones o triggers), p. ej. mesa_de_pedido,
--    que daba la mesa o el nombre de cualquier pedido de cualquier bar.
-- Y lo mismo para las funciones que se creen a partir de ahora.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

do $$
declare
  f record;
  publicas text[] := array['equipo_login', 'correo_pin', 'fichar', 'fichaje_estado', 'carta_publica'];
  internas text[] := array['mesa_de_pedido', 'fichaje_comprobar', 'tbai_nueva_serie', 'cuenta_abierta', 'misma_empresa',
                           'factura_encadenada', 'auditar_cobro_fuera_turno'];
begin
  for f in
    select p.oid::regprocedure as firma, p.proname as nombre
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
  loop
    execute format('revoke execute on function %s from public, anon', f.firma);
    if f.nombre = any (internas) then
      execute format('revoke execute on function %s from authenticated', f.firma);
    else
      execute format('grant execute on function %s to authenticated', f.firma);
    end if;
    if f.nombre = any (publicas) then
      execute format('grant execute on function %s to anon', f.firma);
    end if;
  end loop;
end $$;

-- Las funciones nuevas no quedan abiertas a todo el mundo por defecto
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges in schema public grant execute on functions to authenticated;
