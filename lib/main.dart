import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'core/tema.dart';
import 'features/auth/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // En Android (TPV): pantalla completa, sin barras del sistema; reaparecen deslizando desde el borde.
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
  await Supabase.initialize(
    url: Config.supabaseUrl,
    anonKey: Config.supabaseKey,
  );
  runApp(const GestionRestApp());
}

/// Acceso corto al cliente de Supabase.
SupabaseClient get supabase => Supabase.instance.client;

/// Cambia para que la app vuelva a cargar la sesión (p. ej. al cambiar de empresa).
final recargaApp = ValueNotifier<int>(0);

class GestionRestApp extends StatelessWidget {
  const GestionRestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GestiónRest',
      debugShowCheckedModeBanner: false,
      theme: temaGestionRest(),
      locale: const Locale('es'),
      supportedLocales: const [Locale('es')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const AuthGate(),
    );
  }
}
