-- 0027 · Caducidad de certificados y copia diaria en Drive.
-- Ejecutar entero en el SQL Editor. Se puede ejecutar más de una vez.
-- El bloque 3 (programar la copia) va aparte y comentado: hay que poner tus claves.

-- =====================================================================
-- 1 · Caducidad de los certificados de firma
-- Cada equipo con certificado apunta aquí cuándo caduca (al abrir la Barra con internet) y el
-- panel apunta el del servidor. El panel avisa 30 días antes: el día que caduca no se firma.
-- =====================================================================
create table if not exists public.tbai_certificados (
  empresa_id     uuid not null default public.empresa_actual() references public.empresa(id) on delete cascade,
  origen         text not null,            -- 'servidor' o 'equipo B1'
  titular        text,
  caduca         timestamptz not null,
  actualizado_en timestamptz not null default now(),
  primary key (empresa_id, origen)
);

alter table public.tbai_certificados enable row level security;
drop policy if exists "por_empresa" on public.tbai_certificados;
create policy "por_empresa" on public.tbai_certificados as restrictive for all to authenticated
  using (empresa_id = (select public.empresa_actual()))
  with check (empresa_id = (select public.empresa_actual()));
drop policy if exists "leer_certificados" on public.tbai_certificados;
create policy "leer_certificados" on public.tbai_certificados for select to authenticated
  using ((select public.mi_rol()) is not null);
-- Lo escribe el equipo que tiene el certificado, lo use quien lo use (camarero en el TPV)
drop policy if exists "apuntar_certificados" on public.tbai_certificados;
create policy "apuntar_certificados" on public.tbai_certificados for insert to authenticated
  with check ((select public.mi_rol()) is not null);
drop policy if exists "actualizar_certificados" on public.tbai_certificados;
create policy "actualizar_certificados" on public.tbai_certificados for update to authenticated
  using ((select public.mi_rol()) is not null) with check ((select public.mi_rol()) is not null);

-- =====================================================================
-- 2 · ¿Está programada la copia? Ejecuta esto y mira el resultado:
--   · error "schema cron does not exist" → falta activar pg_cron (Database → Extensions)
--   · ninguna fila → la copia automática nunca se programó
--   · fila 'copia-mensual' con '0 3 2 * *' → la antigua (una vez al mes): cámbiala con el bloque 3
-- =====================================================================
-- select jobname, schedule, active from cron.job;
-- Y si alguna vez se ejecutó, cómo fue (las últimas 5):
-- select j.jobname, d.status, d.start_time, d.return_message
--   from cron.job_run_details d join cron.job j using (jobid)
--  order by d.start_time desc limit 5;

-- =====================================================================
-- 3 · Copia TODOS LOS DÍAS a las 03:00 UTC (04:00 en invierno, 05:00 en verano en Madrid).
-- Cada día guarda el mes en curso (sustituye el zip del mes) y los días 1 y 2 también el
-- mes anterior, para que quede completo. Si falla, correo a AVISOS_CORREO (función).
-- Antes: Database → Extensions → activar pg_cron y pg_net.
-- Cambia TU_CLAVE_ANON (Settings → API → anon public) y TU_SECRETO (el mismo que el secreto
-- COPIA_SECRETO de la función). Ejecuta solo este bloque cuando lo tengas:
-- =====================================================================
-- do $$ begin
--   if exists (select 1 from cron.job where jobname = 'copia-mensual') then
--     perform cron.unschedule('copia-mensual');
--   end if;
--   if exists (select 1 from cron.job where jobname = 'copia-diaria') then
--     perform cron.unschedule('copia-diaria');
--   end if;
-- end $$;
-- select cron.schedule('copia-diaria', '0 3 * * *', $cron$
--   select net.http_post(
--     url := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/copia-mensual',
--     headers := jsonb_build_object('Content-Type', 'application/json',
--                                   'Authorization', 'Bearer TU_CLAVE_ANON',
--                                   'x-copia-secreto', 'TU_SECRETO'),
--     body := '{}'::jsonb,
--     timeout_milliseconds := 300000)
-- $cron$);
