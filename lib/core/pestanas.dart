import 'package:flutter/material.dart';

import '../features/auth/perfil.dart';
import 'software.dart';
import 'tema.dart';

typedef Pestana = ({String texto, IconData icono, String permiso, Widget Function() pagina});

/// Agrupa varias pantallas en pestañas, mostrando solo las que el usuario puede ver.
class Pestanas extends StatelessWidget {
  const Pestanas({super.key, required this.pestanas});
  final List<Pestana> pestanas;

  @override
  Widget build(BuildContext context) {
    final p = Perfil.cache;
    final visibles = [
      for (final x in pestanas)
        if (x.permiso == 'programa' ? Software.esProgramador : (p?.puede(x.permiso) ?? false)) x
    ];
    if (visibles.isEmpty) return const Center(child: Text('Sin permisos'));
    if (visibles.length == 1) return visibles.first.pagina();
    return DefaultTabController(
      length: visibles.length,
      child: Column(children: [
        Material(
          color: C.crema,
          child: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: C.tinta,
            indicatorColor: C.verde,
            tabs: [for (final x in visibles) Tab(icon: Icon(x.icono), text: x.texto)],
          ),
        ),
        Expanded(child: TabBarView(children: [for (final x in visibles) x.pagina()])),
      ]),
    );
  }
}
