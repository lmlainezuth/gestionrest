-- 0054 · Alta de bares desde la app, certificado guardado en el servidor y paso a producción.
--
--  · Certificado del titular: se sube desde la app (Ajustes › Programa, solo programadores) y se guarda
--    aquí CIFRADO por la función "alta-bar" (AES-256-GCM, llave en el secreto TBAI_CLAVE_MAESTRA de las
--    funciones, fuera de la base). Las tablas no tienen reglas de acceso: desde la app no se leen.
--  · Alta de un bar en un solo paso (alta_bar_crear), en entorno "pruebas".
--  · Producción: solo la función del servidor la activa (pasar_produccion), tras comprobarlo todo, y
--    de producción no se vuelve. El administrador sigue pudiendo cambiar entre simulado y pruebas.
--  · Equipos con serie propia: al pasar el bar a producción piden solos una serie nueva.
--
-- Las funciones nuevas solo las llama el servidor (clave de servicio), salvo tbai_renovar_serie_equipo.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.

-- =====================================================================
-- 1 · Almacén de certificados
-- =====================================================================
create table if not exists public.tbai_certificados_guardados (
  empresa_id uuid primary key references public.empresa(id) on delete cascade,
  cifrado    text not null check (char_length(cifrado) <= 100000),  -- base64(iv || AES-256-GCM)
  nif        text not null,          -- NIF del bar con el que se comprobó al subirlo
  titular    text not null,
  caduca     timestamptz not null,
  huella     text not null,          -- SHA-256 del certificado (no es secreto)
  subido_por uuid,
  subido_en  timestamptz not null default now()
);

-- Los anteriores: sin el cifrado, solo quién era, hasta cuándo valía y quién lo subió
create table if not exists public.tbai_certificados_historial (
  id            uuid primary key default gen_random_uuid(),
  empresa_id    uuid not null references public.empresa(id) on delete cascade,
  titular       text,
  caduca        timestamptz,
  huella        text,
  subido_por    uuid,
  subido_en     timestamptz,
  sustituido_en timestamptz not null default now()
);

alter table public.tbai_certificados_guardados enable row level security;
alter table public.tbai_certificados_historial enable row level security;
-- Sin políticas: ni la app ni un programador los leen. Solo la clave de servicio (funciones).
revoke all on table public.tbai_certificados_guardados from public, anon, authenticated;
revoke all on table public.tbai_certificados_historial from public, anon, authenticated;

-- =====================================================================
-- 2 · NIF con su control (DNI, NIE, CIF). Igual que la app (lib/core/nif.dart)
-- =====================================================================
create or replace function public.nif_valido(p_nif text)
returns boolean
language plpgsql immutable
set search_path = ''
as $$
declare
  n text := upper(trim(coalesce(p_nif, '')));
  letras constant text := 'TRWAGMYFPDXBNJZSQVHLCKE';
  suma int := 0;
  d int;
  c int;
begin
  if n ~ '^\d{8}[A-Z]$' then
    return substr(letras, (substr(n, 1, 8)::bigint % 23)::int + 1, 1) = substr(n, 9, 1);
  end if;
  if n ~ '^[XYZ]\d{7}[A-Z]$' then
    return substr(letras, (((strpos('XYZ', substr(n, 1, 1)) - 1)::text || substr(n, 2, 7))::bigint % 23)::int + 1, 1)
           = substr(n, 9, 1);
  end if;
  if n ~ '^[ABCDEFGHJNPQRSUVW]\d{7}[0-9A-J]$' then
    for i in 1..7 loop
      d := substr(n, i + 1, 1)::int;
      if i % 2 = 0 then
        suma := suma + d;
      else
        suma := suma + (d * 2) / 10 + (d * 2) % 10;
      end if;
    end loop;
    c := (10 - suma % 10) % 10;
    return substr(n, 9, 1) = c::text or substr(n, 9, 1) = substr('JABCDEFGHI', c + 1, 1);
  end if;
  return false;
end $$;

-- =====================================================================
-- 3 · Entorno: a producción solo el servidor, y de producción no se sale
-- =====================================================================
create or replace function public.tbai_entorno_servidor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' and old.entorno = 'produccion' and new.entorno is distinct from 'produccion' then
    raise exception 'El bar ya factura en producción: no se puede volver a pruebas ni a simulado';
  end if;
  -- Desde la app (sesión de usuario) no se pasa a producción: lo hace la función "alta-bar"
  if new.entorno = 'produccion' and (tg_op = 'INSERT' or old.entorno is distinct from 'produccion')
     and coalesce(auth.role(), '') in ('authenticated', 'anon') then
    raise exception 'El paso a producción lo hace el programador en Ajustes › Programa › Estado de los bares';
  end if;
  return new;
end $$;
drop trigger if exists tbai_entorno_servidor on public.tbai_config;
create trigger tbai_entorno_servidor before insert or update on public.tbai_config
for each row execute function public.tbai_entorno_servidor();

-- =====================================================================
-- 4 · Qué falta para pasar a producción (verde o rojo, con el motivo)
-- =====================================================================
create or replace function public.alta_bar_comprobaciones(p_empresa uuid)
returns jsonb
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_cfg record;
  v_prog record;
  v_cert record;
  v_pin int;
  v_espera int;
  v_pend int;
  r jsonb := '[]'::jsonb;
  ok boolean;
begin
  select t.nif, t.entorno into v_cfg from public.tbai_config t where t.empresa_id = p_empresa;
  if not found then
    raise exception 'Ese bar no existe o no tiene datos fiscales';
  end if;
  select p.licencia_pruebas, p.licencia_produccion, p.nif_desarrollador, p.nombre_desarrollador
    into v_prog from public.programa p limit 1;
  select g.nif, g.caduca into v_cert from public.tbai_certificados_guardados g where g.empresa_id = p_empresa;
  select count(*) into v_pin
    from public.empresa_usuarios eu join public.perfiles p on p.id = eu.usuario_id
   where eu.empresa_id = p_empresa and eu.activo and p.correo like '%@gestionrest.local' and not p.pin_seguro;
  select count(*) into v_espera from public.ventas_espera v
   where v.empresa_id = p_empresa and not exists (select 1 from public.facturas f where f.id = v.id);
  select (select count(*) from public.facturas f where f.empresa_id = p_empresa and f.estado_envio = 'pendiente')
       + (select count(*) from public.tbai_anulaciones a where a.empresa_id = p_empresa and a.estado_envio = 'pendiente')
       + (select count(*) from public.tbai_subsanaciones s where s.empresa_id = p_empresa and s.estado_envio = 'pendiente')
    into v_pend;

  ok := coalesce(v_cfg.entorno is distinct from 'produccion', false);
  r := r || jsonb_build_object('clave', 'entorno', 'ok', ok,
    'texto', case when ok then 'Entorno actual: ' || v_cfg.entorno else 'El bar ya está en producción' end);

  ok := coalesce(coalesce(trim(v_prog.licencia_produccion), '') <> ''
        and v_prog.licencia_produccion is distinct from v_prog.licencia_pruebas
        and v_prog.licencia_produccion not ilike 'TBAIGIPRE%', false);
  r := r || jsonb_build_object('clave', 'licencia', 'ok', ok,
    'texto', case when ok then 'Licencia definitiva: ' || v_prog.licencia_produccion
                  else 'Falta la licencia definitiva (Ajustes › Programa): la de pruebas no vale' end);

  ok := coalesce(char_length(coalesce(trim(v_prog.nif_desarrollador), '')) = 9 and coalesce(trim(v_prog.nombre_desarrollador), '') <> '', false);
  r := r || jsonb_build_object('clave', 'desarrollador', 'ok', ok,
    'texto', case when ok then 'Datos del desarrollador puestos' else 'Faltan el nombre o el NIF del desarrollador (Ajustes › Programa)' end);

  ok := coalesce(v_cfg.nif <> 'B00000000' and public.nif_valido(v_cfg.nif), false);
  r := r || jsonb_build_object('clave', 'nif', 'ok', ok,
    'texto', case when ok then 'NIF del bar: ' || v_cfg.nif else 'El NIF del bar (' || coalesce(v_cfg.nif, 'vacío') || ') no es un NIF real' end);

  ok := coalesce(v_cert.nif is not null and v_cert.nif = v_cfg.nif and v_cert.caduca > now(), false);
  r := r || jsonb_build_object('clave', 'certificado', 'ok', ok,
    'texto', case
      when v_cert.nif is null then 'El certificado no está en el almacén: súbelo o pásalo desde los secretos del panel'
      when v_cert.nif <> v_cfg.nif then 'El certificado guardado es de otro NIF (' || v_cert.nif || '): sube el del titular'
      when v_cert.caduca <= now() then 'El certificado caducó el ' || to_char(v_cert.caduca, 'DD/MM/YYYY')
      else 'Certificado válido hasta el ' || to_char(v_cert.caduca, 'DD/MM/YYYY') end);

  r := r || jsonb_build_object('clave', 'pin', 'ok', v_pin = 0,
    'texto', case when v_pin = 0 then 'Todos tienen PIN de 6 cifras' else v_pin || ' persona(s) con el PIN antiguo sin cambiar' end);
  r := r || jsonb_build_object('clave', 'espera', 'ok', v_espera = 0,
    'texto', case when v_espera = 0 then 'Ninguna venta en espera' else v_espera || ' venta(s) en espera sin resolver (Facturas › Ventas en espera)' end);
  r := r || jsonb_build_object('clave', 'pendientes', 'ok', v_pend = 0,
    'texto', case when v_pend = 0 then 'Nada pendiente de enviar a Hacienda' else v_pend || ' fichero(s) de pruebas sin enviar todavía' end);
  return r;
end $$;
revoke all on function public.alta_bar_comprobaciones(uuid) from public, anon, authenticated;
grant execute on function public.alta_bar_comprobaciones(uuid) to service_role;

-- =====================================================================
-- 5 · Guardar el certificado (alta, sustitución o desde el secreto antiguo)
-- =====================================================================
create or replace function public.guardar_certificado_bar(p_empresa uuid, p_nif text, p_cifrado text, p_titular text,
                                                          p_caduca timestamptz, p_huella text, p_usuario uuid, p_motivo text)
returns void
language plpgsql security definer
set search_path = ''
as $$
begin
  -- Comprobado contra el NIF que tiene el bar AHORA (por si alguien lo cambió mientras tanto)
  if not exists (select 1 from public.tbai_config t where t.empresa_id = p_empresa and t.nif = upper(trim(p_nif))) then
    raise exception 'El NIF del bar ha cambiado: vuelve a subir el certificado';
  end if;
  insert into public.tbai_certificados_historial (empresa_id, titular, caduca, huella, subido_por, subido_en)
  select g.empresa_id, g.titular, g.caduca, g.huella, g.subido_por, g.subido_en
    from public.tbai_certificados_guardados g where g.empresa_id = p_empresa;
  insert into public.tbai_certificados_guardados (empresa_id, cifrado, nif, titular, caduca, huella, subido_por, subido_en)
  values (p_empresa, p_cifrado, upper(trim(p_nif)), p_titular, p_caduca, p_huella, p_usuario, now())
  on conflict (empresa_id) do update set cifrado = excluded.cifrado, nif = excluded.nif, titular = excluded.titular,
    caduca = excluded.caduca, huella = excluded.huella, subido_por = excluded.subido_por, subido_en = excluded.subido_en;
  -- Para el aviso de caducidad que ya existe (panel del administrador)
  insert into public.tbai_certificados (empresa_id, origen, titular, caduca, actualizado_en)
  values (p_empresa, 'servidor', p_titular, p_caduca, now())
  on conflict (empresa_id, origen) do update set titular = excluded.titular, caduca = excluded.caduca,
    actualizado_en = excluded.actualizado_en;
  insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
  values (p_empresa, 'certificado_subido', p_usuario,
          left(coalesce(p_motivo, 'Certificado nuevo') || ' · caduca el ' || to_char(p_caduca, 'DD/MM/YYYY'), 500));
end $$;
revoke all on function public.guardar_certificado_bar(uuid, text, text, text, timestamptz, text, uuid, text) from public, anon, authenticated;
grant execute on function public.guardar_certificado_bar(uuid, text, text, text, timestamptz, text, uuid, text) to service_role;

-- =====================================================================
-- 6 · Alta de un bar, todo o nada
-- =====================================================================
create or replace function public.alta_bar_crear(p_id uuid, p_nombre text, p_razon text, p_nif text, p_admin uuid, p_admin_nombre text,
                                                 p_programador uuid, p_cifrado text, p_titular text, p_caduca timestamptz,
                                                 p_huella text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v uuid;
  v_nif text := upper(trim(coalesce(p_nif, '')));
  v_serie text;
begin
  if coalesce(trim(p_nombre), '') = '' or char_length(trim(p_nombre)) > 100 then
    raise exception 'Falta el nombre del bar (como mucho 100 caracteres)';
  end if;
  if coalesce(trim(p_razon), '') = '' or char_length(trim(p_razon)) > 120 then
    raise exception 'Falta el titular (como mucho 120 caracteres)';
  end if;
  if v_nif = 'B00000000' or not public.nif_valido(v_nif) then
    raise exception 'El NIF % no es válido', v_nif;
  end if;
  if not exists (select 1 from public.programadores where usuario_id = p_programador) then
    raise exception 'Solo un programador da de alta bares';
  end if;
  -- El id lo elige la función: el certificado ya va cifrado atado a él
  insert into public.empresa (id, nombre, documento_fiscal) values (p_id, trim(p_nombre), v_nif) returning id into v;
  -- Primero el PIN seguro: sin él la base no deja hacerle administrador (0041)
  update public.perfiles set nombre = trim(p_admin_nombre), empresa_actual = v, pin_seguro = true where id = p_admin;
  if not found then
    raise exception 'No se encontró la cuenta del administrador';
  end if;
  -- El programador queda como administrador (para elegir el bar la primera vez en el TPV) y el
  -- primer administrador del bar, con su cuenta de PIN ya creada por la función
  insert into public.empresa_usuarios (empresa_id, usuario_id, rol, activo) values
    (v, p_programador, 'admin', true),
    (v, p_admin, 'admin', true);
  insert into public.tbai_config (empresa_id, nif, razon_social, entorno) values (v, v_nif, upper(trim(p_razon)), 'pruebas');
  insert into public.areas_preparacion (empresa_id, nombre) values (v, 'Cocina'), (v, 'Barra');
  insert into public.cajas (empresa_id, nombre) values (v, 'Caja principal');
  insert into public.conceptos_gasto (empresa_id, nombre) values
    (v, 'Proveedor'), (v, 'Cambio / monedas'), (v, 'Limpieza'), (v, 'Reparaciones'), (v, 'Otros');
  v_serie := public.tbai_nueva_serie(v, 'caja', 'Caja principal');
  perform public.guardar_certificado_bar(v, v_nif, p_cifrado, p_titular, p_caduca, p_huella, p_programador, 'Certificado del alta');
  insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
  values (v, 'alta_bar', p_programador, left('Alta del bar ' || trim(p_nombre) || ' (' || v_nif || ') en pruebas', 500));
  return jsonb_build_object('empresa_id', v, 'serie', v_serie);
end $$;
revoke all on function public.alta_bar_crear(uuid, text, text, text, uuid, text, uuid, text, text, timestamptz, text) from public, anon, authenticated;
grant execute on function public.alta_bar_crear(uuid, text, text, text, uuid, text, uuid, text, text, timestamptz, text) to service_role;

-- =====================================================================
-- 7 · Paso a producción, todo o nada
-- =====================================================================
create or replace function public.pasar_produccion(p_empresa uuid, p_usuario uuid, p_confirmacion text)
returns jsonb
language plpgsql security definer
set search_path = ''
as $$
declare
  v_nombre text;
  v_falta text;
  v_serie text;
begin
  -- Uno a la vez por bar
  perform 1 from public.tbai_config t where t.empresa_id = p_empresa for update;
  select e.nombre into v_nombre from public.empresa e where e.id = p_empresa;
  if v_nombre is null then
    raise exception 'Ese bar no existe';
  end if;
  if trim(coalesce(p_confirmacion, '')) <> trim(v_nombre) then
    raise exception 'El nombre escrito no coincide con el del bar: no se ha cambiado nada';
  end if;
  select string_agg(c->>'texto', '; ') into v_falta
    from jsonb_array_elements(public.alta_bar_comprobaciones(p_empresa)) c where not (c->>'ok')::boolean;
  if v_falta is not null then
    raise exception 'Falta: %', v_falta;
  end if;
  update public.tbai_config set entorno = 'produccion' where empresa_id = p_empresa;
  -- Serie nueva de producción para la caja; los equipos con serie propia piden la suya solos
  v_serie := public.tbai_nueva_serie(p_empresa, 'caja', 'Caja principal (producción)');
  insert into public.eventos_seguridad (empresa_id, tipo, usuario_id, detalle)
  values (p_empresa, 'paso_produccion', p_usuario, left('Paso a producción. Serie nueva de la caja: ' || v_serie, 500));
  return jsonb_build_object('serie', v_serie);
end $$;
revoke all on function public.pasar_produccion(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.pasar_produccion(uuid, uuid, text) to service_role;

-- =====================================================================
-- 8 · Equipos con serie propia: serie de producción sin pasar por Ajustes
-- =====================================================================
-- Cada serie de pruebas de un equipo se renueva UNA vez (si se pierde la respuesta, la asigna el
-- administrador en Ajustes › Empresa, como siempre)
create table if not exists public.tbai_series_renovadas (
  empresa_id uuid not null references public.empresa(id) on delete cascade,
  anterior   text not null,
  nueva      text not null,
  creada_en  timestamptz not null default now(),
  creada_por uuid default auth.uid(),
  primary key (empresa_id, anterior)
);
alter table public.tbai_series_renovadas enable row level security;
revoke all on table public.tbai_series_renovadas from public, anon, authenticated;

create or replace function public.tbai_renovar_serie_equipo(p_anterior text)
returns text
language plpgsql security definer
set search_path = ''
as $$
declare
  v_empresa uuid := public.empresa_actual();
  v_anterior text := upper(trim(coalesce(p_anterior, '')));
  v_nueva text;
begin
  if public.mi_rol() not in ('admin', 'camarero') then
    raise exception 'Solo quien cobra puede renovar la serie del equipo';
  end if;
  if (select t.entorno from public.tbai_config t where t.empresa_id = v_empresa) is distinct from 'produccion' then
    raise exception 'El bar no está en producción';
  end if;
  if not exists (select 1 from public.tbai_series s where s.empresa_id = v_empresa and s.serie = v_anterior
                    and s.tipo = 'equipo' and s.entorno <> 'produccion') then
    raise exception 'Esa no es una serie de pruebas de un equipo de este bar';
  end if;
  perform pg_advisory_xact_lock(hashtext('tbai_renovar:' || v_empresa || ':' || v_anterior));
  if exists (select 1 from public.tbai_series_renovadas r where r.empresa_id = v_empresa and r.anterior = v_anterior) then
    raise exception 'La serie % ya se renovó: el administrador asigna una a este equipo en Ajustes › Empresa', v_anterior;
  end if;
  v_nueva := public.tbai_nueva_serie(v_empresa, 'equipo', 'Sustituye a ' || v_anterior);
  insert into public.tbai_series_renovadas (empresa_id, anterior, nueva) values (v_empresa, v_anterior, v_nueva);
  return v_nueva;
end $$;
revoke all on function public.tbai_renovar_serie_equipo(text) from public, anon;
grant execute on function public.tbai_renovar_serie_equipo(text) to authenticated;
