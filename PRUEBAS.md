# Pruebas de la tanda de seguridad (bloques 1 a 4 y ventas en espera)

Todo esto se hace **en el entorno de pruebas**: un proyecto de Supabase de pruebas, o el de siempre con el bar
en `tbai_config.entorno = 'pruebas'`, y nunca con datos de clientes reales. El script de API se niega a
seguir si el bar está en producción.

## 0 · Preparación

**Orden de despliegue**

1. Funciones: `supabase functions deploy crear-usuario`, `supabase functions deploy ticketbai` y
   `supabase functions deploy alertas-seguridad --no-verify-jwt`.
2. Netlify (puente y web) a la vez que las funciones: el puente nuevo no funciona con la función antigua.
3. La app nueva en **todos** los equipos de prueba.
4. En el SQL Editor, por orden: `0048`, `0049`, `0050`, `0051` y `0052`.
5. `supabase/datos/comprobar_migraciones.sql` → tiene que salir «✔ Están todas».
6. Si al ejecutar la `0048` salió «pg_cron no está activado»: actívalo en Database › Extensions y vuelve
   a ejecutar su último bloque.

**Lo que hace falta en el bar de pruebas**

| Quién | Para qué |
|---|---|
| Un **administrador** con PIN de 6 cifras (o con correo) | casi todo |
| Un **camarero** con PIN de 6 cifras y los permisos por defecto (mesas, barra, cobrar y anular; **sin** cierres) | casi todo |
| Un **cocinero** | pruebas de cocina |
| Un **empleado «víctima»** que se pueda bloquear | bloqueos de PIN |
| Otros **4 empleados** | bloqueo de todo el bar (opcional) |
| Un **segundo administrador** | cambio de PIN entre administradores |
| Un **Windows con el certificado instalado** y serie propia (Ajustes › Empresa) | cobro sin internet |
| Un **equipo sin certificado** (web o Android) | firma en el servidor |

Para varias pruebas sin internet hay que tocar la cola del equipo. En Windows está en
`%APPDATA%\<carpeta de la app>\shared_preferences.json`, clave `flutter.offline_cola`. Cierra la app
antes de editarla.

---

# Parte 1 · Pruebas desde la app

Las marcadas con **(SQL)** llevan un paso de preparación en el SQL Editor del entorno de pruebas.

## Bloque 1 · PIN

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| 1.1 | Usuarios › Nuevo: camarero con PIN `1234` | «El PIN debe tener entre 6 y 8 cifras». Con `123456`, se crea |
| 1.2 | **(SQL)** `update perfiles set pin_seguro = false where id = '<camarero>';` y entra con su PIN | Sale «Cambia tu PIN» |
| 1.3 | En esa pantalla, PIN actual equivocado | «El PIN actual no es correcto» |
| 1.4 | PIN actual bueno y uno nuevo de 6 cifras, dos veces | Entra normal. En Números › Seguridad: «Cambió su PIN» |
| 1.5 | En la pantalla de entrada, 5 PIN falsos seguidos con la «víctima» | «Demasiados PIN incorrectos. Espera 5 minutos». Con el PIN bueno, también bloqueado hasta pasados 5 min. En Seguridad: 5 PIN incorrectos y 1 bloqueo |
| 1.6 | Ficha sin internet con un empleado; después bloquéalo con 5 PIN falsos (desde otro equipo con red); devuelve la red al primero | El fichaje **sigue en la cola** («Fichajes sin internet en espera…»). Pasados 5 min se sube solo |
| 1.7 | **(SQL)** `select * from cron.job where jobname = 'limpiar-seguridad';` | Existe |
| 1.8 | **(SQL)** `insert into eventos_seguridad (empresa_id, tipo, momento) values ('<bar>', 'prueba', now() - interval '200 days'); select public.limpiar_seguridad();` | El evento de prueba desaparece |

## Bloque 2 · Cuentas y ventas

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| 2.1 | Mesas: pide un plato con un extra de 1 € | En la cuenta, precio del producto + 1 € |
| 2.2 | Cobra una mesa y una venta de barra | Funcionan; la cuenta queda pagada y la mesa libre |
| 2.3 | Barra sin internet: cobra; devuelve la red | Sube sola, queda pagada y aparece su factura |
| 2.4 | Mesas: Dividir la cuenta y después Cancelar el reparto | Todo vuelve a la cuenta original |
| 2.5 | Como camarero, intenta reabrir una cuenta cobrada (si la app lo ofrece) | «Esta cuenta ya está cerrada». Como administrador, sí |
| 2.6 | Cierra la caja dejando 200 €; abre la siguiente con 150 € | En el turno: «Abrió con 150 €; al cerrar se dejaron 200 €». En Seguridad: «Abrió caja con un fondo distinto…» |
| 2.7 | Barra sin internet: cobra un plato. Antes de devolver la red, cambia su precio en Carta (desde otro equipo). Devuelve la red | La línea mantiene el precio cobrado. En Seguridad: «Venta sin internet con un precio distinto…» |

## Bloque 3 · TicketBAI

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| 3.1 | **La más importante.** Windows con certificado: sin internet, cobra en Barra; devuelve la red | El ticket sale. Al volver la red la cola se vacía, la factura aparece en Facturas y queda «enviada». Si queda «en espera» con «La firma del fichero no es válida», **no pases a producción** y avisa |
| 3.2 | Equipo sin certificado, con red: cobra | La factura sale firmada (por el servidor), con QR, y queda «enviada» |
| 3.3 | Windows con certificado, con red: cobra | Firma el equipo, el servidor la acepta y queda «enviada» |
| 3.4 | Dos equipos de la misma caja cobran a la vez (sin serie propia) | Las dos facturas salen, con números seguidos |
| 3.5 | Apaga el puente (o quita la red justo tras cobrar) | La factura queda «pendiente»; al restablecer, se envía sola y queda «enviada» |
| 3.6 | Como administrador, anula una factura | La anulación queda «enviada» y el cobro se descuenta de la caja |
| 3.7 | Como camarero, intenta anular | No se puede; en Seguridad: «Intentó anular una factura sin ser administrador» |
| 3.8 | Provoca un rechazo (factura con NIF de cliente mal escrito) y Subsánala como administrador | La factura pasa a «enviada» (subsanada) |
| 3.9 | **(SQL)** `update tbai_config set entorno = 'simulado' where empresa_id = '<bar>';` cobra; después vuelve a `'pruebas'` | La factura queda «simulada» y no pasa por el puente |
| 3.10 | **(SQL)** La consulta comentada al final de la `0050` | No devuelve filas (si devuelve, pásamelas) |

## Bloque 4 · Permisos

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| 4.1 | Usuarios: deja a un camarero solo con «Mesas y comandas». Entra con él e intenta cobrar, anular un plato y abrir caja | Cada intento falla con «No tienes permiso…» (o la base lo rechaza). Devuélvele los permisos: funciona todo |
| 4.2 | Camarero sin «Cierres»: Caja | Ve la caja abierta; el fondo solo si la abrió él. Ve sus movimientos, no los de otros |
| 4.3 | Camarero sin «Facturas» ni «Informes»: Facturas recientes | Solo ve las que hizo él, las pendientes de envío y las de cuentas sin cobrar |
| 4.4 | Con un solo administrador: Usuarios › quitarle el rol de administrador o desactivarlo | «El bar no puede quedarse sin ningún administrador» |
| 4.5 | Cambia el rol o los permisos de un empleado | En Seguridad: «Cambio de rol, permisos o baja de un empleado» con el detalle |
| 4.6 | Como administrador, Cambiar PIN de **otro administrador** | «El PIN de otro administrador solo lo puede cambiar él mismo». En Seguridad: «Intentó cambiar el PIN de otro administrador» |
| 4.7 | Cambiar PIN de un camarero | Se cambia; en Seguridad: «Cambió el PIN de …» |

## Ventas en espera

Para provocar los rechazos hay que tocar la cola del equipo (ver Preparación). Es solo para la prueba.

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| E.1 | **Firma rechazada.** Windows con certificado, sin internet: cobra en Barra. Cierra la app y en `offline_cola` cambia un carácter del `SignatureValue` dentro de `factura.xml`. Abre la app y devuelve la red | Franja roja: «La venta T…-N no se pudo subir (La firma del fichero no es válida) y queda en espera». En Seguridad: «Venta sin internet que el servidor no aceptó: en espera». En `offline_cola` la venta **sigue**, con `"en_espera": true` |
| E.2 | Con red, cobra otra venta en Barra en ese mismo equipo | Sale el cobro **sin internet** (el diálogo de cobro sin conexión) y la venta queda en la cola detrás |
| E.3 | En Mesas de ese equipo, intenta cobrar con red | Aviso: «Este equipo tiene una venta sin internet en espera: cobra desde Barra…» |
| E.4 | Como administrador (en otro equipo): Facturas › Resolver › Enviar tal cual | Sin motivo (o con menos de 10 letras) el botón está apagado. Con motivo: se guarda, se envía y Hacienda la **rechaza** por la firma → queda «error» y se puede Subsanar. En Seguridad: «Venta en espera enviada a Hacienda tal cual…» con el motivo |
| E.5 | Vuelve al equipo de E.1 | La venta en espera sale de la cola; la de E.2 sube sola y queda «enviada». El equipo vuelve a cobrar con red |
| E.6 | **Cadena rota.** Sin internet, cobra dos ventas (N y N+1). Cierra la app y en `offline_cola` cambia en la **primera** `factura.anterior_id` por otro uuid. Devuelve la red | La primera queda en espera («No encaja en la cadena de la serie…»); la segunda espera detrás |
| E.7 | Administrador: Enviar tal cual | **(SQL)** `select fuera_de_cadena, anterior_id, anterior_serie, anterior_numero from facturas where serie='…' and numero=N;` → `true`, `null` y la referencia del fichero. Hacienda la recibe. En Seguridad: «… (no encadena con la última factura de la serie): motivo» |
| E.8 | Vuelve al equipo | La N+1 sube sola, encadenada a la forzada, y queda «enviada» |
| E.9 | **TPV desinstalado.** Repite E.1 hasta que la venta esté en espera. Desinstala la app de ese equipo (o borra sus datos) | — |
| E.10 | **(SQL o terminal)** Lanza el aviso diario de prueba: `curl -X POST <URL>/functions/v1/alertas-seguridad -H "x-copia-secreto: <secreto>" -d '{"siempre":true}'` | El correo dice «1 venta sin internet en espera (T…-N): Facturas › Ventas en espera», aunque nadie haya forzado nada |
| E.11 | Desde **otro equipo** o la web, como administrador: Facturas › Resolver › Enviar tal cual | Aparecen el pedido (pagado, con sus líneas), el cobro en su turno (si el turno ya estaba cerrado, además «cobro fuera de turno» en Seguridad) y la factura con su envío |
| E.12 | Repite E.10 al día siguiente (o en el momento) | Ya no cuenta esa venta |

---

# Parte 2 · Pruebas por API (script)

`herramientas/pruebas_api.mjs` hace con el **camarero** y el **administrador** de pruebas las llamadas que
la app no hace (lo que intentaría alguien que se salta la app). No lleva claves ni PIN dentro: lo lee
de variables de entorno o lo pregunta al empezar. Necesita Node 18 o más.

**Qué comprueba**

- **Bloque 1:** PIN de 4 cifras rechazado; cambio del PIN propio con el actual equivocado; la app no
  puede llamar a la limpieza.
- **Bloque 2:**
  - Precio de una línea: con 0,01 o negativo queda el del producto.
  - Total a mano, pagado sin cobros y `reparto_de` escrito: rechazados.
  - `cancelar_reparto` con la misma cuenta o con cuentas sin reparto: rechazado.
  - Extras sueltos desde el camarero: denegado.
  - Cuenta nueva con un total escrito: queda a 0.
  - Las cuentas de prueba se anulan al final.
- **Bloque 3:**
  - `firmar` un alta como camarero: 403.
  - `registrar` algo que no cuadra: 400.
  - Insert directo en facturas (camarero, y administrador sin legado): denegado.
  - Cambiar el estado de envío: no cambia.
  - `preparar_envio` sin el secreto del puente: 403.
  - `tbai_ultima_factura` devuelve solo 5 campos.
  - El puente no acepta XML (con `GR_PUENTE_URL`).
  - Cocinero (con `GR_COCINERO_ID`): `probar` 403, `tbai_ultima_factura` vacía, no ve subsanaciones ni anulaciones.
- **Bloque 4:**
  - Camarero sin cierres: no lee turnos; `turno_abierto` responde.
  - Con los permisos recortados a «mesas» (los devuelve como estaban al terminar): `tengo_permiso('cobrar')` falso, abrir turno denegado, fondo sugerido vacío, cuenta de barra rechazada, stock denegado.
  - El único administrador no se quita el rol (solo si el bar tiene uno).
  - Cambiar el PIN de otro administrador: 403 (con `GR_OTRO_ADMIN_ID`).
- **Ventas en espera:**
  - Insertar, cambiar o borrar en `ventas_espera` siendo administrador: denegado.
  - `apartar` con otro NIF o con más de 200 KB: rechazado.
  - `forzar` como camarero: 403; sin motivo: 400.
- **Con `--bloqueos`:** 20 PIN falsos a la vez a la «víctima» → solo se prueban 5; después sigue bloqueado.
- **Con `--bloqueo-bar`:** 20 PIN falsos repartidos entre 4 empleados → el camarero tampoco entra con su
  PIN bueno. **El bar queda sin entrada con PIN 15 minutos**: déjalo para el final.

**Cómo lanzarlo**

PowerShell (pon tus valores; los PIN y la contraseña, si no los pones, los pregunta):

```powershell
$env:GR_URL = 'https://<proyecto-de-pruebas>.supabase.co'
$env:GR_KEY = '<publishable key de ese proyecto>'
$env:GR_EMPRESA = '<id del bar de pruebas>'
$env:GR_CAMARERO_ID = '<id del camarero>'
$env:GR_ADMIN_ID = '<id del administrador>'          # o GR_ADMIN_EMAIL si entra con correo
$env:GR_PUENTE_URL = 'https://<sitio>.netlify.app/api/tbai'   # opcional
$env:GR_COCINERO_ID = '<id del cocinero>'             # opcional
$env:GR_VICTIMA_ID = '<id del empleado que se puede bloquear>'  # para --bloqueos
$env:GR_OTRO_ADMIN_ID = '<id de otro administrador>'  # opcional
node herramientas/pruebas_api.mjs
node herramientas/pruebas_api.mjs --bloqueos
node herramientas/pruebas_api.mjs --bloqueo-bar      # al final: 15 minutos sin PIN en el bar
```

Bash: igual, con `export GR_URL=...`.

Los ids salen de Usuarios (o de `select id, nombre from perfiles;` en el SQL Editor de pruebas).

**Resultado.** Cada línea dice `OK` o `FALLO` con la respuesta del servidor. Al final: «N de M pruebas
bien» y la lista de las que fallan. Pásame esa lista si sale algo.

**Qué deja en la base de pruebas.** Unas cuentas «PRUEBA API» anuladas (y su rastro en el registro de
control), intentos de PIN y eventos en Seguridad, y un cambio de permisos del camarero que se deshace al
terminar. Nada en producción.
