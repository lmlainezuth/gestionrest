-- 0030 · Datos del programa (iguales para todos los bares): nombre y NIF del desarrollador y
-- licencias TicketBAI. Se cambian en la app, en Ajustes › Programa, y solo los programadores.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.
-- Después, el bloque del final (con tu correo) para darte acceso a esa pestaña.

-- Una sola fila. Vacía = la app usa lo que lleva dentro (software.dart / software_privado.dart).
-- El NIF no va aquí escrito a propósito: el repositorio es público. Se rellena desde la app.
create table if not exists public.programa (
  id                   boolean primary key default true check (id),
  nombre_desarrollador text,
  nif_desarrollador    text check (nif_desarrollador is null or length(nif_desarrollador) = 9),
  licencia_pruebas     text,
  licencia_produccion  text,
  actualizado_en       timestamptz not null default now()
);

-- Quién puede cambiarlos
create table if not exists public.programadores (
  usuario_id uuid primary key references auth.users(id) on delete cascade
);

create or replace function public.es_programador()
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (select 1 from public.programadores where usuario_id = auth.uid())
$$;
revoke all on function public.es_programador() from public, anon;
grant execute on function public.es_programador() to authenticated;

alter table public.programa enable row level security;
alter table public.programadores enable row level security;
-- Todos los equipos lo leen (va en cada factura); solo los programadores lo cambian
drop policy if exists "leer_programa" on public.programa;
create policy "leer_programa" on public.programa for select to authenticated using (true);
drop policy if exists "programador_cambia" on public.programa;
create policy "programador_cambia" on public.programa for all to authenticated
  using ((select public.es_programador())) with check ((select public.es_programador()));
-- programadores: sin políticas → desde la app no se lee ni se cambia (solo con SQL)

-- =====================================================================
-- Darte acceso a Ajustes › Programa: cambia el correo por el de TU cuenta de GestiónRest
-- (el que usas para entrar como administrador) y ejecuta solo esto:
-- =====================================================================
-- insert into public.programadores (usuario_id)
-- select id from auth.users where lower(email) = lower('TU_CORREO@ejemplo.com')
-- on conflict do nothing;
-- select u.email from public.programadores p join auth.users u on u.id = p.usuario_id;  -- comprobar
