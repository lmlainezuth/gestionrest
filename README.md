# GestiónRest

Programa de gestión para bares y restaurantes, con TicketBAI para Gipuzkoa.

Autor: **Levin Mauricio Lainez Aguirre** ([lmlainezuth](https://github.com/lmlainezuth))

## Qué hace

- Mesas y comandas, barra (venta rápida) y pantalla de cocina
- Carta y precios
- Caja: apertura, cobro (efectivo, tarjeta, Bizum), cierre y ticket de cierre
- Informes, márgenes e IVA
- Stock, pedidos a proveedores, reservas, fichajes y cuadrante
- Varias empresas (varios bares) en la misma app
- Funciona sin internet y sincroniza al volver la conexión
- Impresoras de tickets y cocina (red, USB y puerto serie) y cajón portamonedas
- Copia de seguridad mensual en Google Drive

## TicketBAI

- Generación del fichero de alta y de anulación, firma XAdES y encadenamiento
- Envío a la Hacienda Foral de Gipuzkoa (entorno de pruebas y de producción)
- Factura simplificada, factura completa con NIF y facturas rectificativas
- Código TicketBAI y QR impresos en el ticket
- Pantalla de verificación presencial (art. 8 de la OF 521/2020)
- Firma en el propio equipo (cobra sin internet) o en el servidor

## Tecnología

- [Flutter](https://flutter.dev) (Android y web)
- [Supabase](https://supabase.com): PostgreSQL con RLS por empresa y Edge Functions (`supabase/functions`)
- Netlify Functions (`netlify/functions/tbai.mjs`): puente TLS con Hacienda

## Compilar

1. Copia `lib/core/software_privado.dart.ejemplo` como `lib/core/software_privado.dart` y pon el NIF de la persona desarrolladora (ese archivo no se sube a git).
2. En `lib/core/config.dart`, pon la URL y la clave publicable de tu proyecto de Supabase.
3. Ejecuta las migraciones de `supabase/migrations` y despliega las funciones de `supabase/functions`.
4. Los certificados y las claves van como secretos de Supabase y variables de Netlify, nunca en el repositorio.
5. `flutter pub get` y `flutter build apk --release`.

## Licencia

Copyright (C) 2026 Levin Mauricio Lainez Aguirre

Este programa es software libre: puedes redistribuirlo y modificarlo según los términos de la Licencia Pública General de GNU, versión 3 ([GPL-3.0](LICENSE)).
