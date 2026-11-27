# Paso a producción de la tanda de seguridad (migraciones 0047 a 0053)

Hay **un solo proyecto de Supabase** (`restgestion1`, `zouujjameuyyedqiotxt`): todo lo probado ya está en el
mismo proyecto que usan los bares. Lo que decide si un bar factura «de verdad» es `tbai_config.entorno`
(`pruebas` = Hacienda lo recibe sin validez fiscal; `produccion` = con validez). Por eso aquí:
**comprobar** que todo está aplicado, **terminar** lo que va fuera de Supabase y, cuando toque, **pasar
cada bar a `produccion`**.

## 0 · Comprobaciones (primero)

### 0.1 Migraciones aplicadas (SQL Editor)

Ejecuta `supabase/datos/comprobar_migraciones.sql` → «✔ Están todas». Y esta, que resume la tanda (todas `true`):

```sql
select comprobacion, ok from (values
  ('0039 · equipo_login ya no da el correo',  not exists (select 1 from pg_proc where proname = 'equipo_login' and pg_get_function_result(oid) like '%correo%')),
  ('0047 · sin carta pública',                to_regproc('public.carta_publica') is null),
  ('0047 · fotos en privado',                 exists (select 1 from storage.buckets where id = 'productos' and not public)),
  ('0048 · PIN con candado y límites',        exists (select 1 from pg_proc where proname = 'fichaje_comprobar' and prosrc like '%pg_advisory_xact_lock%')),
  ('0048 · limpieza programada',              exists (select 1 from cron.job where jobname = 'limpiar-seguridad')),
  ('0049 · precio lo pone la base',           to_regproc('public.precio_de_linea') is not null),
  ('0049 · versión corregida (auth.role)',    exists (select 1 from pg_proc where proname = 'precio_de_linea' and prosrc like '%auth.role()%')),
  ('0049 · pagado con cobros',                to_regproc('public.pagos_cubren') is not null),
  ('0050 · facturas solo por el servidor',    not exists (select 1 from pg_policies where tablename = 'facturas' and policyname in ('camarero_emitir_facturas','camarero_estado_facturas'))),
  ('0051 · permisos en el servidor',          to_regproc('public.turno_abierto') is not null and to_regproc('public.miembros_vigilar') is not null),
  ('0052 · ventas en espera',                 to_regclass('public.ventas_espera') is not null),
  ('0053 · esperas y aviso en la base',       to_regproc('public.reclamar_accion_manual') is not null and to_regproc('public.alertas_resumen') is not null),
  ('0053 · fotos 2 MB',                       exists (select 1 from storage.buckets where id = 'productos' and file_size_limit = 2097152)),
  ('0053 · fichajes 48 h',                    exists (select 1 from pg_proc where proname = 'fichar' and prosrc like '%48 hours%'))
) as t(comprobacion, ok);
```

**Ojo con la 0049:** `precio_de_linea` y `pagos_cubren` se corrigieron en el mismo archivo después del bloque 2.
Si «0049 · versión corregida» sale `false`, vuelve a ejecutar la `0049` entera (se puede repetir).

### 0.2 Cron y datos

```sql
-- Trabajos programados: alertas-seguridad, resumen-diario, limpiar-seguridad y la copia; ninguno con la contraseña de prueba
select jobid, jobname, schedule, active, command like '%prueba123456%' as contraseña_de_prueba
  from cron.job order by jobname;

-- Cómo fueron las últimas ejecuciones del cron
select j.jobname, d.status, d.start_time, left(d.return_message, 120) as mensaje
  from cron.job_run_details d join cron.job j using (jobid)
 order by d.start_time desc limit 10;

-- Qué contestaron las funciones a las últimas llamadas
select created, status_code, left(content, 200) as respuesta
  from net._http_response order by created desc limit 10;

-- En qué entorno está cada bar
select e.nombre, c.entorno, c.nif from public.empresa e join public.tbai_config c on c.empresa_id = e.id order by e.nombre;

-- Ventas sin internet en espera sin resolver
select v.serie, v.numero, v.creado_en, v.motivo_rechazo from public.ventas_espera v
 where not exists (select 1 from public.facturas f where f.id = v.id);

-- Personas que aún tienen que cambiar el PIN (no pueden trabajar hasta hacerlo)
select p.nombre from public.perfiles p where p.correo like '%@gestionrest.local' and not p.pin_seguro;

-- Fotos antiguas sin carpeta de bar (ya no se ven: hay que volver a subirlas)
select name from storage.objects where bucket_id = 'productos' and (storage.foldername(name))[1] is null;
```

### 0.3 Versión desplegada de cada función

**a) Fecha de despliegue (terminal):**

```
supabase functions list --project-ref zouujjameuyyedqiotxt
supabase secrets list --project-ref zouujjameuyyedqiotxt
```

`UPDATED_AT` tiene que ser posterior al último cambio de cada una:

| Función | Último cambio (commit) |
|---|---|
| `alertas-seguridad`, `resumen-diario`, `copia-mensual` | 27/11 21:01 (`756ea99`) |
| `ticketbai`, `crear-usuario` | 27/11 20:19 (`0fdb1f6`) |
| Puente Netlify (`netlify/functions/tbai.mjs`) | 27/11 19:42 (`eaad8e4`) |

Secretos que tienen que estar: `ALERTAS_SECRETO`, `RESUMEN_SECRETO`, `COPIA_SECRETO`, `PUENTE_SECRETO`,
`RESEND_API_KEY`, `AVISOS_CORREO` y, por cada bar, `TBAI_P12_…` y `TBAI_P12_CLAVE_…`.

**b) Por cómo responden (SQL Editor; con contraseña falsa, no hacen nada):**

```sql
select net.http_post(url := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/alertas-seguridad',
  headers := jsonb_build_object('Content-Type','application/json'), body := '{"secreto":"falsa"}'::jsonb);
select net.http_post(url := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/resumen-diario',
  headers := jsonb_build_object('Content-Type','application/json'), body := '{"secreto":"falsa"}'::jsonb);
select net.http_post(url := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/copia-mensual',
  headers := jsonb_build_object('Content-Type','application/json'), body := '{"secreto":"falsa"}'::jsonb);
-- unos segundos después:
select created, status_code, content from net._http_response order by created desc limit 3;
```

- Las tres `403 … el secreto no coincide` → última versión.
- `resumen-diario` con `401 … JWT` → no está desplegada con `--no-verify-jwt` (el cron del resumen fallará).
- Otra respuesta → esa función es de una versión anterior.

`ticketbai`, `crear-usuario` y el puente necesitan sesión: compruébalos con `node herramientas/pruebas_api.mjs`
(ver `PRUEBAS.md`).
- «firmar un alta siendo camarero» y los de «Ventas en espera» en OK → `ticketbai` nueva.
- «PIN de 4 cifras rechazado» en OK → `crear-usuario` nueva.
- Con `GR_PUENTE_URL`, «El puente no acepta XML de la app» en OK → puente nuevo.

## Lo que ya está hecho (solo comprobar)

- Migraciones `0047`–`0053` → 0.1.
- Funciones desplegadas → 0.3.
- Cron programado → 0.2 (que no quede `prueba123456`).
- No hay un proyecto de pruebas separado: no hay nada que «copiar» a producción.

## Lo que queda

1. **Netlify:** publicar web y puente (si no está hecho; lo confirma la prueba del puente en 0.3).
2. **App nueva en todos los equipos** (Windows y Android). La web, con Netlify.
3. **Contraseñas de verdad** en `ALERTAS_SECRETO` y `RESUMEN_SECRETO` (largas y distintas) y las mismas en
   los trabajos del cron: vuelve a ejecutar sus `cron.schedule` (ver más abajo).
4. **0039**, si en 0.1 sale `false`: solo cuando **todos** los equipos tengan la app nueva.
5. **Limpiar las pruebas:** quitar desde Usuarios los usuarios de prueba (víctima, empleados extra, segundo
   administrador). Las facturas de prueba no se borran (son del entorno `pruebas`).
6. **Carteles QR** de las mesas: retirarlos. **Fotos antiguas** (última consulta de 0.2): volver a subirlas.
7. **Revisión de la 0050:** la consulta comentada al final; si devuelve filas, revisarlas.
8. **Pasar cada bar a `produccion`** (el paso fiscal), cuando toque: desde la `0054` se hace en la app,
   Ajustes › Programa › Estado de los bares › «Pasar a producción» (ver el apartado de abajo). Ya no con
   `update tbai_config`: la base lo rechaza desde la app y de producción no se vuelve.
9. **Git:** unir `seguridad-auditoria` con `main` cuando todo esté comprobado.
10. **Memoria de TicketBAI:** actualizar el proceso (arquitectura, firma, registro, envío, anulaciones,
    custodia del certificado) y añadir el apartado de contingencia (ventas en espera).

### Cron con las contraseñas de verdad

`resumen-diario` y `alertas-seguridad` se despliegan con `--no-verify-jwt` y la contraseña va en el cuerpo.
Cambia solo la contraseña (la misma que en el secreto) y, si quieres, la hora (en UTC: `6` = 7:00 en España en
invierno). Ejecutar de nuevo `cron.schedule` con el mismo nombre sustituye el trabajo.

```sql
select cron.schedule('alertas-seguridad', '30 6 * * *', $c$
  select net.http_post(
    url     := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/alertas-seguridad',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := '{"secreto": "CONTRASEÑA_DE_ALERTAS_SECRETO"}'::jsonb);
$c$);

select cron.schedule('resumen-diario', '0 6 * * *', $c$
  select net.http_post(
    url     := 'https://zouujjameuyyedqiotxt.supabase.co/functions/v1/resumen-diario',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := '{"secreto": "CONTRASEÑA_DE_RESUMEN_SECRETO"}'::jsonb);
$c$);
```

Para probar el aviso al momento: la misma llamada con `{"siempre": true, "secreto": "…"}` (llega el correo aunque
no haya nada). En el botón Test del panel, o la cabecera se llama `x-copia-secreto` (no `ALERTAS_SECRETO`), o la
contraseña va en el cuerpo como `"secreto"`.

## Alta de bares desde la app (migración 0054)

Lo que tienes que ejecutar, **en este orden** (la `0054` antes que `ticketbai`: la función nueva lee una
tabla que crea la migración).

1. **Llave del almacén de certificados.** En PowerShell, genera 32 bytes al azar:

   ```powershell
   $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b)
   ```

   Guarda el resultado en tu gestor de contraseñas. **Si se pierde, los certificados guardados no se pueden
   abrir** y hay que volver a subirlos todos. Después:

   ```
   supabase secrets set TBAI_CLAVE_MAESTRA=<el valor> --project-ref zouujjameuyyedqiotxt
   ```

2. **SQL Editor:** ejecuta entera `supabase/migrations/0054_alta_bar.sql`. Luego
   `supabase/datos/comprobar_migraciones.sql` → «✔ Están todas».
3. **Funciones:**

   ```
   supabase functions deploy alta-bar --project-ref zouujjameuyyedqiotxt
   supabase functions deploy ticketbai --project-ref zouujjameuyyedqiotxt
   supabase functions deploy alertas-seguridad --no-verify-jwt --project-ref zouujjameuyyedqiotxt
   ```

   `alta-bar` y `ticketbai` llevan la carpeta `_shared`: el CLI la incluye solo.
4. **App nueva** en tu equipo de programador y, después, en los equipos de los bares (la renovación
   automática de series y el cambio en Ajustes › Empresa van en la app).
5. **Pruebas:** `PRUEBAS.md` › «Alta de bares (0054)» y el script con `GR_PROGRAMADOR_EMAIL`.
6. **Bar actual:** Estado de los bares › «Pasar al almacén». Cobra un ticket en una tablet y comprueba que
   llega a Hacienda. Entonces borra `TBAI_P12_<ID>` y `TBAI_P12_CLAVE_<ID>` del panel y repite la prueba.
7. **Producción de un bar**, cuando toque: licencia definitiva y datos del desarrollador en Ajustes ›
   Programa, y luego Estado de los bares › «Pasar a producción». Los equipos con serie propia piden la suya
   solos al subir lo que tenían pendiente; si alguno no puede, el administrador se la asigna en Ajustes ›
   Empresa.
