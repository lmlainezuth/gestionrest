import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'features/auth/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: Config.supabaseUrl,
    anonKey: Config.supabaseKey,
  );
  runApp(const GestionRestApp());
}

/// Acceso corto al cliente de Supabase.
SupabaseClient get supabase => Supabase.instance.client;

class GestionRestApp extends StatelessWidget {
  const GestionRestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GestiónRest',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2E7D32),
        useMaterial3: true,
      ),
      home: const AuthGate(),
    );
  }
}
