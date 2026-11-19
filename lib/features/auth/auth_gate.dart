import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/empresa_dispositivo.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../admin/admin_home.dart';
import '../camarero/camarero_home.dart';
import '../cocina/cocina_home.dart';
import 'login_page.dart';
import 'perfil.dart';

/// Elige empresa si hace falta y abre la pantalla según el rol y permisos.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  // La carga del perfil se hace UNA vez por usuario (y al pedir recarga). Antes se repetía en
  // cada aviso de sesión (inicio, renovación del token...) y se veían dos cargas seguidas.
  Future<(Perfil?, List<Map<String, dynamic>>)>? _futuro;
  String? _claveFuturo;

  Future<(Perfil?, List<Map<String, dynamic>>)> _futuroPara(String clave) {
    if (_futuro == null || _claveFuturo != clave) {
      _claveFuturo = clave;
      _futuro = _preparar();
    }
    return _futuro!;
  }

  /// Secciones que se ven en el panel completo (no solo mesas y barra).
  static const _panel = [
    'carta', 'caja', 'facturas', 'informes', 'usuarios', 'ajustes',
    'caja_diaria', 'gastos', 'proveedores', 'resumen',
  ];

  Future<(Perfil?, List<Map<String, dynamic>>)> _preparar() async {
    var perfil = await Perfil.actual();
    if (perfil == null) return (null, <Map<String, dynamic>>[]);
    // La empresa de este equipo manda, si el usuario pertenece a ella
    final disp = await EmpresaDispositivo.leer();
    if (disp != null && perfil.empresaId != disp) {
      if (await supabase.rpc('usar_empresa', params: {'p_empresa': disp}) == true) {
        perfil = await Perfil.actual();
      }
    }
    if (perfil!.empresaId == null || !perfil.activo) {
      final empresas = List<Map<String, dynamic>>.from(await supabase.rpc('mis_empresas'));
      if (empresas.length != 1) return (perfil, empresas);
      await supabase.rpc('usar_empresa', params: {'p_empresa': empresas.first['id']});
      perfil = await Perfil.actual();
    }
    if (perfil?.empresaId != null) await EmpresaDispositivo.guardar(perfil!.empresaId!);
    return (perfil, <Map<String, dynamic>>[]);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: supabase.auth.onAuthStateChange,
      builder: (context, _) {
        if (supabase.auth.currentSession == null) return const LoginPage();
        return ValueListenableBuilder<int>(
          valueListenable: recargaApp,
          builder: (context, v, _) => FutureBuilder<(Perfil?, List<Map<String, dynamic>>)>(
            key: ValueKey('${supabase.auth.currentUser?.id}-$v'),
            future: _futuroPara('${supabase.auth.currentUser?.id}-$v'),
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Scaffold(body: Center(child: CircularProgressIndicator()));
              }
              if (snap.hasError) return _Aviso('No se pudo cargar tu perfil:\n${snap.error}');
              final (perfil, empresas) = snap.data!;
              if (perfil == null) return const _Aviso('No se encontró tu perfil.');
              if (perfil.empresaId == null || !perfil.activo) {
                return empresas.isEmpty
                    ? const _Aviso('Tu cuenta no tiene acceso a ninguna empresa.\nPide al administrador que te dé acceso.')
                    : _ElegirEmpresa(empresas: empresas);
              }
              if (perfil.rol == Rol.cocinero) return CocinaHome(perfil: perfil);
              if (perfil.esAdmin || _panel.any(perfil.puede)) return AdminHome(perfil: perfil);
              return CamareroHome(perfil: perfil);
            },
          ),
        );
      },
    );
  }
}

class _ElegirEmpresa extends StatelessWidget {
  const _ElegirEmpresa({required this.empresas});
  final List<Map<String, dynamic>> empresas;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('¿Con qué empresa trabajas?', style: titulo(28)),
                const SizedBox(height: 6),
                const Text('Este equipo la recordará.', style: TextStyle(color: C.gris)),
                const SizedBox(height: 20),
                for (final e in empresas)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 64)),
                      onPressed: () async {
                        await supabase.rpc('usar_empresa', params: {'p_empresa': e['id']});
                        await EmpresaDispositivo.guardar(e['id'] as String);
                        recargaApp.value++;
                      },
                      child: Text(e['nombre'] as String, style: titulo(20)),
                    ),
                  ),
                TextButton(onPressed: () => supabase.auth.signOut(), child: const Text('Cerrar sesión')),
              ],
            ),
          ),
        ),
      ),
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
              FilledButton(onPressed: () => supabase.auth.signOut(), child: const Text('Cerrar sesión')),
            ],
          ),
        ),
      ),
    );
  }
}
