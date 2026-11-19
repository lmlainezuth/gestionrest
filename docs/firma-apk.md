# Firma del APK de GestionRest (art. 9 OF 521/2020)

Cada APK que se instala en un TPV o una tablet tiene que ir firmado con el certificado de firma de código de Certum (Open Source Code Signing, en la nube con SimplySign) y hay que guardar una copia de cada versión distribuida. El script `herramientas\firmar_apk.ps1` hace las dos cosas.

## Preparación (una sola vez)

1. Activa el certificado en Certum e instala **SimplySign Desktop** en el PC y la app **SimplySign** en el móvil.
2. Copia `herramientas\simplysign.cfg.ejemplo` como `herramientas\simplysign.cfg`. Si en `C:\Windows\System32` no está `SimplySignPKCS.dll`, cambia la ruta por la librería que haya instalado SimplySign.
3. Conecta SimplySign Desktop (usuario + código de la app del móvil) y saca el alias del certificado:
   ```
   keytool -list -keystore NONE -storetype PKCS11 -providerClass sun.security.pkcs11.SunPKCS11 -providerArg herramientas\simplysign.cfg
   ```
   `keytool` y `apksigner` necesitan Java: sirve el que trae Android Studio (carpeta `jbr\bin`, en el PATH).

## Cada versión nueva

1. Sube la versión en `lib\core\software.dart` (por ejemplo de 1.0 a 1.1). Es la que va en los ficheros TicketBAI y en la verificación presencial.
2. Con SimplySign Desktop conectado:
   ```
   powershell -ExecutionPolicy Bypass -File herramientas\firmar_apk.ps1 -Alias "<alias>"
   ```
   Compila, firma, comprueba la firma y deja `versiones-apk\<versión>\GestionRest-<versión>.apk` con un `LEEME.txt` (fecha y SHA-256). No deja firmar dos veces la misma versión.
3. Copia la carpeta `versiones-apk` fuera del PC (Drive). Está en `.gitignore`: no se sube a GitHub.
4. Comunica la versión nueva al Registro de Software TicketBAI.

## La primera vez que se instala un APK firmado con Certum

Los equipos que ya tienen GestionRest firmado con la clave de depuración no aceptan una actualización con otra firma. En cada equipo:

1. Comprueba que no queda nada pendiente de enviar (la franja de aviso no sale).
2. Desinstala GestionRest e instala el APK firmado.
3. Vuelve a entrar con la empresa y, en el TPV, instala otra vez el certificado del titular y su serie propia.

## Al renovar el certificado de Certum (cada 459 días como máximo)

Si el certificado nuevo trae otra clave, Android tampoco aceptará la actualización. Para evitarlo se encadena la clave antigua con la nueva (rotación de clave, APK Signature Scheme v3).

Hazlo **antes de que caduque el certificado antiguo**, porque hace falta firmar con los dos:

1. Con los dos certificados activos en SimplySign, crea un `.cfg` para cada uno: `simplysign-antiguo.cfg` y `simplysign-nuevo.cfg`, cambiando `slotListIndex` (0, 1… en el orden de SimplySign Desktop).
2. Crea el linaje una sola vez:
   ```
   apksigner rotate --out herramientas\linaje-certum.bin ^
     --old-signer --ks NONE --ks-type PKCS11 --ks-provider-class sun.security.pkcs11.SunPKCS11 --ks-provider-arg herramientas\simplysign-antiguo.cfg --ks-key-alias "<alias antiguo>" ^
     --new-signer --ks NONE --ks-type PKCS11 --ks-provider-class sun.security.pkcs11.SunPKCS11 --ks-provider-arg herramientas\simplysign-nuevo.cfg --ks-key-alias "<alias nuevo>"
   ```
3. Desde entonces, firma cada versión con los dos y el linaje:
   ```
   apksigner sign --ks NONE --ks-type PKCS11 --ks-provider-class sun.security.pkcs11.SunPKCS11 --ks-provider-arg herramientas\simplysign-antiguo.cfg --ks-key-alias "<alias antiguo>" ^
     --next-signer --ks NONE --ks-type PKCS11 --ks-provider-class sun.security.pkcs11.SunPKCS11 --ks-provider-arg herramientas\simplysign-nuevo.cfg --ks-key-alias "<alias nuevo>" ^
     --lineage herramientas\linaje-certum.bin --out versiones-apk\<versión>\GestionRest-<versión>.apk <apk alineado>
   ```
4. Guarda `linaje-certum.bin` junto a las versiones archivadas: hace falta para todas las versiones siguientes.

Limitaciones:

- La rotación solo la reconocen los equipos con **Android 9 o superior**. En uno más antiguo (por ejemplo un Sunmi T2 con Android 7) hay que hacer lo de "La primera vez": desinstalar e instalar.
- Estos comandos de rotación no se han podido probar todavía, porque hacen falta los dos certificados. Pruébalos con una versión de prueba en un equipo antes de que caduque el antiguo.
