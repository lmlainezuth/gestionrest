import 'package:flutter/material.dart';

import '../../main.dart';
import '../auth/perfil.dart';
import 'cocina_page.dart';

class CocinaHome extends StatelessWidget {
  const CocinaHome({super.key, required this.perfil});
  final Perfil perfil;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(child: CocinaPage(onSalir: () => supabase.auth.signOut())),
      );
}
