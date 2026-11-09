import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import '../admin/admin_home.dart';
import '../camarero/camarero_home.dart';
import '../cocina/cocina_home.dart';
import 'login_page.dart';
import 'perfil.dart';

/// Decide qué pantalla mostrar: login, cuenta pendiente o la del rol.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, _) {
        if (supabase.auth.currentSession == null) return const LoginPage();
        return FutureBuilder<Perfil?>(
          key: ValueKey(supabase.auth.currentUser?.id),
          future: Perfil.actual(),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return _Aviso('No se pudo cargar tu perfil:\n${snap.error}');
            }
            final perfil = snap.data;
            if (perfil == null || !perfil.activo) {
              return const _Aviso(
                'Tu cuenta está pendiente de activación.\n'
                'Pide al administrador que te asigne un rol.',
              );
            }
            return switch (perfil.rol) {
              Rol.admin => AdminHome(perfil: perfil),
              Rol.camarero => CamareroHome(perfil: perfil),
              Rol.cocinero => CocinaHome(perfil: perfil),
            };
          },
        );
      },
    );
  }
}

class _Aviso extends StatelessWidget {
  const _Aviso(this.texto);
  final String texto;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(texto, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => supabase.auth.signOut(),
                child: const Text('Cerrar sesión'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
