-- 0017 · Fichaje de empleados (registro de jornada, art. 34.9 ET)
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.
--
-- · Cada empleado ficha con SU PIN (el mismo de entrar a la app) desde la pantalla de entrada.
-- · Los registros no se modifican ni se borran nunca: una corrección es un registro nuevo
--   que apunta al original, con motivo y quién la hizo. Se conservan (mínimo 4 años).
-- · Sin internet el TPV guarda el fichaje con su hora y lo sube después (origen "sin_conexion").

create table if not exists public.fichajes (
  id             uuid primary key default gen_random_uuid(),
  empresa_id     uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  usuario_id     uuid references public.perfiles(id) on delete set null,
  nombre         text not null,                 -- copia: el registro sigue legible aunque se borre el usuario
  tipo           text not null check (tipo in ('entrada','pausa','vuelta','salida')),
  momento        timestamptz not null,          -- hora del fichaje
  registrado_en  timestamptz not null default now(),
  origen         text not null default 'tpv' check (origen in ('tpv','sin_conexion','correccion')),
  corrige_id     uuid references public.fichajes(id),
  anula          boolean not null default false, -- registro que deja sin efecto a corrige_id
  motivo         text,
  hecho_por      uuid references public.perfiles(id) on delete set null,
  check (origen <> 'correccion' or (motivo is not null and length(trim(motivo)) > 0)),
  check (not anula or corrige_id is not null)
);
create index if not exists fichajes_empresa_momento_idx on public.fichajes (empresa_id, momento);
create index if not exists fichajes_usuario_momento_idx on public.fichajes (usuario_id, momento);
create index if not exists fichajes_corrige_idx on public.fichajes (corrige_id);

create table if not exists public.fichaje_intentos (
  usuario_id  uuid not null,
  momento     timestamptz not null default now()
);
create index if not exists fichaje_intentos_idx on public.fichaje_intentos (usuario_id, momento);
alter table public.fichaje_intentos enable row level security;   -- sin políticas: solo las funciones

-- Inmutables ------------------------------------------------------------------------
create or replace function public.fichaje_inmutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Un fichaje no se puede modificar ni borrar: añade una corrección con motivo';
end $$;
drop trigger if exists fichaje_inmutable on public.fichajes;
create trigger fichaje_inmutable before update or delete on public.fichajes
for each row execute function public.fichaje_inmutable();

-- Vigentes: los que ninguna corrección posterior sustituye o anula ---------------------
create or replace view public.fichajes_vigentes
with (security_invoker = true) as
  select f.* from public.fichajes f
   where not f.anula
     and not exists (select 1 from public.fichajes c where c.corrige_id = f.id);

-- PIN: misma clave que el acceso (lib/features/auth/pin.dart) --------------------------
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
       where usuario_id = p_usuario and momento > now() - interval '15 minutes') >= 5 then
    raise exception 'Demasiados PIN incorrectos. Espera 15 minutos';
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

-- Lo que ve el empleado: sus fichajes desde el lunes ------------------------------------
create or replace function public.fichaje_estado(p_empresa uuid, p_usuario uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_nombre text := public.fichaje_comprobar(p_empresa, p_usuario, p_pin);
begin
  if v_nombre is null then
    return jsonb_build_object('error', 'PIN incorrecto');
  end if;
  return jsonb_build_object(
    'nombre', v_nombre,
    'registros', coalesce((
      select jsonb_agg(jsonb_build_object('tipo', f.tipo, 'momento', f.momento) order by f.momento)
        from public.fichajes_vigentes f
       where f.empresa_id = p_empresa and f.usuario_id = p_usuario
         and f.momento >= (date_trunc('week', now() at time zone 'Europe/Madrid') at time zone 'Europe/Madrid')
    ), '[]'::jsonb));
end $$;
grant execute on function public.fichaje_estado(uuid, uuid, text) to anon, authenticated;

-- Fichar ---------------------------------------------------------------------------
create or replace function public.fichar(p_empresa uuid, p_usuario uuid, p_pin text, p_tipo text,
                                         p_momento timestamptz default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_nombre text := public.fichaje_comprobar(p_empresa, p_usuario, p_pin);
  v_ultimo text;
  v_fila public.fichajes;
begin
  if v_nombre is null then
    return jsonb_build_object('error', 'PIN incorrecto');
  end if;
  if p_tipo not in ('entrada','pausa','vuelta','salida') then
    raise exception 'Tipo de fichaje no válido';
  end if;
  if p_momento is null then
    -- En el momento: tiene que seguir el orden lógico
    select f.tipo into v_ultimo from public.fichajes_vigentes f
     where f.empresa_id = p_empresa and f.usuario_id = p_usuario and f.momento > now() - interval '20 hours'
     order by f.momento desc limit 1;
    v_ultimo := coalesce(v_ultimo, 'salida');
    if (p_tipo = 'entrada' and v_ultimo <> 'salida')
       or (p_tipo = 'pausa' and v_ultimo not in ('entrada','vuelta'))
       or (p_tipo = 'vuelta' and v_ultimo <> 'pausa')
       or (p_tipo = 'salida' and v_ultimo = 'salida') then
      raise exception 'No puedes fichar % ahora (lo último fue %)', p_tipo, v_ultimo;
    end if;
  elsif p_momento > now() + interval '5 minutes' or p_momento < now() - interval '7 days' then
    raise exception 'Hora del fichaje guardado sin internet fuera de plazo';
  end if;

  insert into public.fichajes (empresa_id, usuario_id, nombre, tipo, momento, origen)
  values (p_empresa, p_usuario, v_nombre, p_tipo, coalesce(p_momento, now()),
          case when p_momento is null then 'tpv' else 'sin_conexion' end)
  returning * into v_fila;
  return to_jsonb(v_fila);
end $$;
grant execute on function public.fichar(uuid, uuid, text, text, timestamptz) to anon, authenticated;

-- Seguridad: el admin de la empresa ve todo y corrige; cada uno ve lo suyo ----------------
alter table public.fichajes enable row level security;
drop policy if exists "por_empresa" on public.fichajes;
create policy "por_empresa" on public.fichajes as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()))
  with check (empresa_id = (select public.empresa_actual()));
drop policy if exists "leer_fichajes" on public.fichajes;
create policy "leer_fichajes" on public.fichajes for select to authenticated
  using ((select public.mi_rol()) = 'admin' or usuario_id = (select auth.uid()));
drop policy if exists "corregir_fichajes" on public.fichajes;
create policy "corregir_fichajes" on public.fichajes for insert to authenticated
  with check ((select public.mi_rol()) = 'admin' and origen = 'correccion' and hecho_por = (select auth.uid()));
