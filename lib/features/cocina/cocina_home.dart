import 'package:flutter/material.dart';

import '../../main.dart';
import '../auth/perfil.dart';

class CocinaHome extends StatelessWidget {
  const CocinaHome({super.key, required this.perfil});
  final Perfil perfil;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Cocina · ${perfil.nombre}'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      body: const Center(
        child: Text('Aquí aparecerán las comandas pendientes.'),
      ),
    );
  }
}
