# Pruebas de la tanda de seguridad (bloques 1 a 5 y ventas en espera)

Todo esto se hace **en el entorno de pruebas**: un proyecto de Supabase de pruebas, o el de siempre con el bar
en `tbai_config.entorno = 'pruebas'`, y nunca con datos de clientes reales. El script de API se niega a
seguir si el bar está en producción.

## 0 · Preparación

**Orden de despliegue**

1. Funciones: `supabase functions deploy crear-usuario`, `supabase functions deploy ticketbai` y
   `supabase functions deploy alertas-seguridad --no-verify-jwt`.
2. Netlify (puente y web) a la vez que las funciones: el puente nuevo no funciona con la función antigua.
3. La app nueva en **todos** los equipos de prueba.
4. En el SQL Editor, por orden: `0048`, `0049`, `0050`, `0051`, `0052` y `0053`. La `0053` va
   **antes** de desplegar las funciones del bloque 5 (`resumen-diario`, `copia-mensual`,
   `alertas-seguridad`, `ticketbai` y `crear-usuario`).
   - Bloque 5: crea los secretos `RESUMEN_SECRETO` y `ALERTAS_SECRETO` y vuelve a programar sus
     dos trabajos de cron con el bloque comentado al final de la `0053`.
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

## Bloque 5 · Resto

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| 5.1 | Panel de hoy como administrador (o Ajustes › Empresa › Comprobar certificado) | **(SQL)** `select origen, caduca, actualizado_en from tbai_certificados;` → la fila «servidor» con la fecha de ahora (la escribe el servidor) |
| 5.2 | Ficha sin internet en un TPV; **(SQL o mirando el fichero)** revisa `flutter.fichajes_cola` en el equipo | La entrada lleva `id`, empresa, usuario, tipo y hora, **sin `p_pin`**. Al volver la red se sube |
| 5.3 | Con una versión anterior de la app, ficha sin internet (queda con el PIN en claro); instala la nueva y ábrela | El PIN desaparece de `fichajes_cola` y el fichaje se sube igual |
| 5.4 | Carta: sube una foto de más de 2 MB | «la imagen pesa más de 2 MB: redúcela antes de subirla» |
| 5.5 | Control › Panel: «Enviar resumen» dos veces seguidas | La segunda: «Ya se envió un resumen hace poco» |
| 5.6 | Ajustes › Copias: «Hacer copia ahora» dos veces seguidas | La segunda: «Ya se hizo una copia hace poco: espera media hora» |
| 5.7 | Usuarios: da de alta 11 usuarios seguidos | El undécimo: «Demasiadas altas seguidas». En Seguridad, «Alta de un usuario» por cada una y «Demasiadas altas…» |
| 5.8 | **(SQL)** `select public.tbai_asignar_serie('equipo');` en un bar en simulado con el NIF de otro bar en producción | La serie que da no se salta las que ese otro bar tiene como `facturas.cadena` en simulado |
| 5.9 | Lanza `alertas-seguridad` con `{"siempre":true}` y el secreto **nuevo** `ALERTAS_SECRETO` | Llega el correo. Con el secreto viejo (`COPIA_SECRETO`): 403 |
| 5.10 | **(SQL)** Crea una función de prueba `create function public.prueba_x() returns int language sql as 'select 1';` y mira `select has_function_privilege('anon', 'public.prueba_x()', 'execute');`. Bórrala después (`drop function public.prueba_x();`) | `false`: las funciones nuevas ya no quedan abiertas a anon |

## Alta de bares (0054)

Antes: la `0054` en el SQL Editor, el secreto `TBAI_CLAVE_MAESTRA` creado y las funciones `alta-bar` y
`ticketbai` desplegadas (ver «Lo que tienes que ejecutar», en PRODUCCION.md). Todo como programador
(cuenta de correo), en Ajustes › Programa.

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| A.1 | Estado de los bares › el bar de pruebas | Sale «En los secretos del panel (antiguo)» con su titular y su caducidad. En «Para pasar a producción», «El certificado no está en el almacén» en rojo |
| A.2 | Comprobar el certificado del bar de pruebas (Ajustes › Empresa › Comprobar certificado) **antes** de A.3 | Sigue funcionando con el secreto antiguo |
| A.3 | «Pasar al almacén» | «Certificado en el almacén. Ya está en el almacén: borra los secretos…». El certificado sale «subido el» hoy. **(SQL)** `select empresa_id, nif, titular, caduca, left(cifrado, 20) from tbai_certificados_guardados;` → una fila con el cifrado ilegible |
| A.4 | Cobra un ticket en una tablet (firma el servidor) y mira que llega a Hacienda de pruebas | Firmado y enviado como siempre, ahora con el certificado del almacén. Después ya puedes borrar `TBAI_P12_<ID>` y `TBAI_P12_CLAVE_<ID>` y repetir: sigue funcionando |
| A.5 | «Sustituir por uno nuevo» con la contraseña mal | «La contraseña no abre el certificado» |
| A.6 | «Sustituir por uno nuevo» con un certificado de otra persona (o el autofirmado `test/fixtures/prueba_tbai.p12`, contraseña 1234) | «El certificado es de «…», no del NIF del bar (…)» |
| A.7 | «Sustituir por uno nuevo» con el mismo certificado bueno | Guardado. **(SQL)** `select titular, caduca, sustituido_en from tbai_certificados_historial;` → el anterior, sin cifrado |
| A.8 | Alta de bar: paso 1 con NIF `12345678A` | «NIF no válido». Con `B00000000`: «Ese es el NIF de relleno» |
| A.9 | Alta de bar completa, con un **titular de pruebas cuyo certificado tengas** (puede ser el mismo del bar de pruebas: el NIF puede repetirse en otro bar) | Al final, la serie de la caja (distinta de las del otro bar con ese NIF). En Estado de los bares aparece en «Pruebas de Hacienda», certificado en el almacén |
| A.10 | En un equipo: entra con tu correo, elige el bar nuevo, sal | En la pantalla de entrada sale el administrador nuevo y entra con su PIN de 6 cifras, sin que le pida cambiarlo |
| A.11 | Como administrador del bar (no programador): Ajustes › Empresa | El entorno solo ofrece Simulado y Pruebas. Ajustes › Programa no aparece |
| A.12 | Estado del bar nuevo › «Pasar a producción» | «Todavía no se puede» con lo que falta (por ejemplo la licencia definitiva). **No lo pases a producción con datos de prueba**: el de verdad se hace con el bar real |
| A.13 | Panel Seguridad del bar nuevo y aviso diario del día siguiente (o `alertas-seguridad` con `{"siempre":true}`) | «Alta del bar», «Certificado del titular subido…» y, si probaste A.12 por la API, «Intento de pasar a producción que no se hizo» |
| A.14 | Quita del bar nuevo los usuarios de prueba cuando acabes | — |

## Cocina (0056)

Antes: la `0056` en el SQL Editor (al final dice en «Messages» cuántos platos atascados pasó a servido) y
la app nueva. Para saber antes cuántos cambiará, la consulta comentada al principio de la migración.

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| C.1 | Abre Cocina después de ejecutar la `0056` | El plato de 1521 minutos ya no está. **(SQL)** `select count(*) from pedido_detalle where estado_cocina in ('pendiente','preparando','listo') and creado_en < now() - interval '24 hours';` → 0 |
| C.2 | Pide un plato de cocina en una mesa y no lo marques en Cocina; cobra la mesa | En Cocina desaparece al cobrar. En la comanda el plato sale como servido |
| C.3 | Igual, pero marca el plato «preparando» en Cocina antes de cobrar | También pasa a servido al cobrar |
| C.4 | Cobra una venta **sin internet** con un plato de cocina; vuelve la red | Al subirse, el plato queda servido (no aparece en Cocina) |
| C.5 | Pide un plato en una mesa, déjala **abierta** y cierra la caja | El plato pasa a servido y desaparece de Cocina. La mesa sigue abierta y se puede cobrar al día siguiente |
| C.6 | **(SQL)** `update pedido_detalle set creado_en = now() - interval '25 hours' where id = '<un plato pendiente>';` y recarga Cocina | Ya no se ve (solo carga las últimas 24 horas) |
| C.7 | Ajustes › Empresa como administrador: apaga «Usa pantalla de cocina» y guarda | La pestaña Cocina desaparece del menú. Un plato nuevo de cocina sale ya como servido en la comanda y no va a ninguna pantalla |
| C.8 | Con el bar sin pantalla de cocina, entra con un cocinero | La pantalla avisa en amarillo «Este bar no usa la pantalla de cocina…» y no le llega nada |
| C.9 | Como camarero, Ajustes › Empresa (si lo ve) | El interruptor está desactivado: solo lo cambia el administrador |
| C.10 | Vuelve a encender «Usa pantalla de cocina» | Cocina vuelve a aparecer y los platos nuevos vuelven a llegar |
| C.11 | Después de C.2 a C.7: Números › Anulaciones y Números › Seguridad | **Nada nuevo**: pasar a servido no es una anulación ni un evento de seguridad. **(SQL)** `select count(*) from registro_anulaciones where momento > now() - interval '1 hour';` → solo lo que anulaste tú a propósito |

## Cobro rápido (0057)

Antes: la `0057` en el SQL Editor y, **después**, desplegar `ticketbai` e instalar la app nueva. Entra como
administrador: el aviso del cronómetro sale tras cada cobro.

| # | Qué hacer | Qué tiene que pasar |
|---|---|---|
| R.1 | Barra: venta rápida nueva y cobrar | Salen «Guardar y leer la cuenta» (ya no «Leer la cuenta» aparte), «Caja, turno, datos fiscales y número (ya leídos)» y, bajo el servidor, «Sesión, rol, datos fiscales y consultas (una sola)». Total cerca de 1 s |
| R.2 | Barra: cuenta con nombre ya abierta, añade algo y cobra | Cobra con el total correcto (precios de la carta, no los del equipo) |
| R.3 | Barra: plato con extras | El precio incluye los extras, como antes |
| R.4 | Ticket **con NIF** | Se cobra bien (la numeración con NIF se lee al cobrar: «Última factura y número» sin «ya leídos») |
| R.5 | Cobro desde una **mesa** y de una **cuenta dividida** | Se cobran bien; el cronómetro también sale |
| R.6 | Dos equipos cobrando a la vez en la misma caja | Los dos tickets salen con números seguidos; si coinciden, uno tarda algo más (vuelve a numerar solo) |
| R.7 | Abre la ventana de cobro, espera más de 1 minuto y cobra | Cobra bien (lo vuelve a leer todo) |
| R.8 | **(SQL)** `select prosecdef from pg_proc where proname = 'guardar_ronda_barra';` | `false`: guarda la ronda con los permisos de quien llama, no con los del servidor |
| R.9 | Venta sin internet que se sube al volver la red | Se sube y se envía como antes |

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
- **Bloque 5:**
  - El camarero no lee `tbai_certificados`; nadie escribe la fila «servidor» desde la app.
  - Fichar con hora de hace 3 días: fuera de plazo.
  - PIN de alguien que no es del bar: misma respuesta que un PIN incorrecto.
  - La app no puede llamar a `reclamar_accion_manual` ni a `alertas_resumen`.
  - Fotos: ni HTML ni más de 2 MB.
- **Alta de bares (0054):**
  - Camarero y administrador con PIN: `alta-bar` 403.
  - El administrador no lee el almacén ni el historial de certificados; la app no puede llamar a
    `alta_bar_crear`, `pasar_produccion`, `guardar_certificado_bar` ni `alta_bar_comprobaciones`.
  - Renovar la serie de un equipo con el bar en pruebas: rechazado.
  - Con `GR_PROGRAMADOR_EMAIL`: lista de bares; estado con 8 comprobaciones y sin el certificado;
    un fichero que no es certificado, rechazado; alta con NIF no válido o PIN de 4 cifras, rechazada
    sin crear nada; pasar a producción con el nombre mal escrito, rechazado y el entorno igual
    (queda apuntado como «intento de pasar a producción» en Seguridad).
  - Con `GR_CERT` y `GR_CERT_CLAVE` (el .p12 del titular del bar de pruebas): contraseña mal,
    otro NIF y el bueno.
- **Cocina (0056):** un camarero no puede apagar la pantalla de cocina del bar.
- **Con `--entorno`:** el administrador intenta pasar el bar a producción por la API → rechazado. Si la
  `0054` no estuviera aplicada pasaría: el script lo vuelve a dejar como estaba en el acto y lo marca
  como fallo. **Lánzalo solo con «0054_alta_bar» en verde en `comprobar_migraciones.sql`.**
- **Con `--esperas`:** resumen y copia manuales dos veces seguidas (la segunda, 429) y dos resúmenes a
  la vez (solo pasa uno). **Manda un correo de resumen y hace una copia en Drive**.
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
$env:GR_PROGRAMADOR_EMAIL = '<tu correo de programador>'  # alta de bares (la contraseña la pregunta)
$env:GR_CERT = 'C:\ruta\certificado-del-titular.pfx'    # opcional
$env:GR_CERT_CLAVE = '<su contraseña>'                    # opcional
node herramientas/pruebas_api.mjs
node herramientas/pruebas_api.mjs --entorno          # solo con la 0054 aplicada
node herramientas/pruebas_api.mjs --bloqueos
node herramientas/pruebas_api.mjs --esperas          # manda un resumen y hace una copia
node herramientas/pruebas_api.mjs --bloqueo-bar      # al final: 15 minutos sin PIN en el bar
```

Bash: igual, con `export GR_URL=...`.

Los ids salen de Usuarios (o de `select id, nombre from perfiles;` en el SQL Editor de pruebas).

**Resultado.** Cada línea dice `OK` o `FALLO` con la respuesta del servidor. Al final: «N de M pruebas
bien» y la lista de las que fallan. Pásame esa lista si sale algo.

**Qué deja en la base de pruebas.** Unas cuentas «PRUEBA API» anuladas (y su rastro en el registro de
control), intentos de PIN y eventos en Seguridad, y un cambio de permisos del camarero que se deshace al
terminar. Nada en producción.
