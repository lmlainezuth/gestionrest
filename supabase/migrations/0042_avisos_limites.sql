-- 0042 · Tercera tanda de arreglos de la auditoría (27/11/2026).
-- 1) Cobro apuntado en un turno ya cerrado (p. ej. venta sin internet que sube tarde): se acepta,
--    pero queda en el registro de control como "cobro_fuera_turno" y sale en el panel y en el cierre.
-- 2) Fichar sin internet: se rechazan los fichajes imposibles (dos entradas seguidas, una vuelta sin
--    pausa…) mirando el fichaje anterior a esa hora. La app enseña al dueño cuándo llegó cada uno.
-- 3) Tras 5 PIN fallidos se espera 5 minutos (antes 15): bloquear a alguien a propósito molesta menos.
-- 4) Límites de longitud en los textos que escribe el personal (la base es compartida por todos los
--    bares). Solo para lo nuevo: NOT VALID no revisa lo que ya hay.
-- 5) Resumen diario: como mucho 5 correos y un envío a mano cada 10 minutos (lo controla la función).
-- 6) Sin sesión no se lee ninguna tabla (todo lo público va por funciones: carta, entrada, fichar),
--    tampoco por tiempo real.
-- ORDEN: esta migración ANTES de desplegar la función resumen-diario nueva (usa resumen_manual_en).
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Cobros en un turno cerrado: se apuntan
-- =====================================================================
alter table public.registro_anulaciones drop constraint if exists registro_anulaciones_tipo_check;
alter table public.registro_anulaciones add constraint registro_anulaciones_tipo_check
  check (tipo in ('linea_anulada','linea_borrada','pedido_anulado','venta_anulada',
                  'factura_anulada','devolucion','quitado_antes_cobrar','cobro_fuera_turno','linea_reducida'));

create or replace function public.auditar_cobro_fuera_turno()
returns trigger
language plpgsql security definer
set search_path = ''
as $$
declare
  v_cerrado timestamptz;
begin
  select t.cerrado_en into v_cerrado from public.turnos_caja t
   where t.id = new.turno_id and t.estado = 'cerrado';
  if found then
    insert into public.registro_anulaciones
      (empresa_id, usuario_id, tipo, descripcion, importe, pedido_id, mesa, motivo)
    values (new.empresa_id, auth.uid(), 'cobro_fuera_turno', 'Cobro en ' || new.metodo, new.importe,
            new.pedido_id, public.mesa_de_pedido(new.pedido_id),
            'El turno se cerró el ' || to_char(v_cerrado at time zone 'Europe/Madrid', 'DD/MM HH24:MI')
            || ': este cobro no está en su cuadre');
  end if;
  return new;
end $$;
revoke all on function public.auditar_cobro_fuera_turno() from public, anon, authenticated;
drop trigger if exists auditar_cobro_fuera_turno on public.pagos;
create trigger auditar_cobro_fuera_turno after insert on public.pagos
for each row execute function public.auditar_cobro_fuera_turno();

-- =====================================================================
-- 2 y 3 · PIN: 5 minutos de espera; fichar sin internet con orden lógico
-- =====================================================================
create or replace function public.fichaje_comprobar(p_empresa uuid, p_usuario uuid, p_pin text)
returns text   -- nombre del empleado, o null si el PIN no es correcto (el intento queda apuntado)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text;
  v_ok boolean;
begin
  if (select count(*) from public.fichaje_intentos
       where usuario_id = p_usuario and momento > now() - interval '5 minutes') >= 5 then
    raise exception 'Demasiados PIN incorrectos. Espera 5 minutos';
  end if;
  select p.nombre,
         extensions.crypt('GRpin-' || p_pin || '-' || split_part(p.correo, '@', 1), u.encrypted_password) = u.encrypted_password
    into v_nombre, v_ok
    from public.perfiles p
    join public.empresa_usuarios eu on eu.usuario_id = p.id and eu.empresa_id = p_empresa and eu.activo
    join auth.users u on u.id = p.id
   where p.id = p_usuario;
  if v_nombre is null then
    raise exception 'Este empleado no pertenece a este bar';
  end if;
  if not coalesce(v_ok, false) then
    insert into public.fichaje_intentos (usuario_id) values (p_usuario);
    return null;   -- sin excepción: si no, se desharía el intento apuntado
  end if;
  delete from public.fichaje_intentos where usuario_id = p_usuario;
  return v_nombre;
end $$;
revoke execute on function public.fichaje_comprobar(uuid, uuid, text) from public, anon, authenticated;

create or replace function public.fichar(p_empresa uuid, p_usuario uuid, p_pin text, p_tipo text,
                                         p_momento timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text := public.fichaje_comprobar(p_empresa, p_usuario, p_pin);
  v_cuando timestamptz := coalesce(p_momento, now());
  v_ultimo text;
  v_fila public.fichajes;
begin
  if v_nombre is null then
    return jsonb_build_object('error', 'PIN incorrecto');
  end if;
  if p_tipo not in ('entrada','pausa','vuelta','salida') then
    raise exception 'Tipo de fichaje no válido';
  end if;
  if p_momento is not null and (p_momento > now() + interval '5 minutes' or p_momento < now() - interval '7 days') then
    raise exception 'Hora del fichaje guardado sin internet fuera de plazo';
  end if;
  -- En el momento o sin internet, tiene que seguir el orden lógico respecto al fichaje anterior
  -- a esa hora (sin internet, el anterior es el que había antes de la hora guardada)
  select f.tipo into v_ultimo from public.fichajes_vigentes f
   where f.empresa_id = p_empresa and f.usuario_id = p_usuario
     and f.momento < v_cuando and f.momento > v_cuando - interval '20 hours'
   order by f.momento desc limit 1;
  v_ultimo := coalesce(v_ultimo, 'salida');
  if (p_tipo = 'entrada' and v_ultimo <> 'salida')
     or (p_tipo = 'pausa' and v_ultimo not in ('entrada','vuelta'))
     or (p_tipo = 'vuelta' and v_ultimo <> 'pausa')
     or (p_tipo = 'salida' and v_ultimo = 'salida') then
    raise exception 'No puedes fichar % a esa hora (lo anterior fue %)', p_tipo, v_ultimo;
  end if;

  insert into public.fichajes (empresa_id, usuario_id, nombre, tipo, momento, origen)
  values (p_empresa, p_usuario, v_nombre, p_tipo, v_cuando,
          case when p_momento is null then 'tpv' else 'sin_conexion' end)
  returning * into v_fila;
  return to_jsonb(v_fila);
end $$;
grant execute on function public.fichar(uuid, uuid, text, text, timestamptz) to anon, authenticated;

-- =====================================================================
-- 4 · Longitud de los textos (solo lo que se escriba a partir de ahora)
-- =====================================================================
do $$
declare
  r record;
  v_nombre text;
begin
  for r in select * from (values
    ('pedido_detalle', 'descripcion', 200), ('pedido_detalle', 'nota', 500), ('pedido_detalle', 'anulado_motivo', 500),
    ('pedidos', 'nombre_llevar', 100), ('pedidos', 'nota', 500),
    ('reservas', 'nombre', 100), ('reservas', 'telefono', 30), ('reservas', 'nota', 500),
    ('clientes', 'nombre', 200), ('clientes', 'documento', 30), ('clientes', 'telefono', 30), ('clientes', 'direccion', 300),
    ('gastos', 'concepto', 200),
    ('proveedores', 'nombre', 200), ('proveedores', 'suministra', 200), ('proveedores', 'telefono', 30),
    ('cajas_diarias', 'notas', 500), ('movimientos_caja', 'descripcion', 200), ('turnos_caja', 'nota', 500),
    ('fichajes', 'motivo', 500), ('perfiles', 'nombre', 100), ('empresa', 'nombre', 150),
    ('facturas', 'xml', 200000)
  ) as t(tabla, columna, maximo)
  loop
    v_nombre := r.tabla || '_' || r.columna || '_largo';
    if not exists (select 1 from pg_constraint where conname = v_nombre) then
      execute format('alter table public.%I add constraint %I check (char_length(%I) <= %s) not valid',
                     r.tabla, v_nombre, r.columna, r.maximo);
    end if;
  end loop;
end $$;

-- =====================================================================
-- 5 · Resumen diario
-- =====================================================================
alter table public.empresa add column if not exists resumen_manual_en timestamptz;
alter table public.empresa drop constraint if exists empresa_correo_resumen_max;
alter table public.empresa add constraint empresa_correo_resumen_max
  check (correo_resumen is null or array_length(string_to_array(correo_resumen, ','), 1) <= 5) not valid;

-- =====================================================================
-- 6 · Sin sesión no se lee ninguna tabla
-- =====================================================================
revoke all on all tables in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
