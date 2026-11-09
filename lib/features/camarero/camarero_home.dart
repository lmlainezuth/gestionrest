import 'package:flutter/material.dart';

import '../../main.dart';
import '../auth/perfil.dart';
import 'mesas_view.dart';

class CamareroHome extends StatelessWidget {
  const CamareroHome({super.key, required this.perfil});
  final Perfil perfil;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Mesas · ${perfil.nombre}'),
        actions: [
          IconButton(
            tooltip: 'Cerrar sesión',
            icon: const Icon(Icons.logout),
            onPressed: () => supabase.auth.signOut(),
          ),
        ],
      ),
      body: const MesasView(),
    );
  }
}
