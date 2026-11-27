import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/auth/perfil.dart';
import '../main.dart';
import 'tema.dart';

/// Escucha en tiempo real cuando cocina marca un plato como listo y avisa
/// al camarero de ese pedido (el admin recibe todos).
class AvisosListo extends StatefulWidget {
  const AvisosListo({super.key, required this.child});
  final Widget child;

  @override
  State<AvisosListo> createState() => _AvisosListoState();
}

class _AvisosListoState extends State<AvisosListo> {
  RealtimeChannel? _canal;
  final Set<String> _avisados = {};

  @override
  void initState() {
    super.initState();
    _canal = supabase
        .channel('avisos-listo-${supabase.auth.currentUser?.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'pedido_detalle',
          filter: Perfil.cache?.empresaId == null
              ? null
              : PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'empresa_id', value: Perfil.cache!.empresaId!),
          callback: _cambio,
        )
        .subscribe();
  }

  Future<void> _cambio(PostgresChangePayload p) async {
    final r = p.newRecord;
    final id = r['id'] as String?;
    if (id == null || r['estado_cocina'] != 'listo' || _avisados.contains(id)) return;
    _avisados.add(id);
    try {
      final pedido = await supabase
          .from('pedidos')
          .select('camarero_id, nombre_llevar, mesas(nombre)')
          .eq('id', r['pedido_id'])
          .single();
      final yo = Perfil.cache;
      if (yo == null) return;
      if (!yo.esAdmin && pedido['camarero_id'] != yo.id) return;
      final mesa = (pedido['mesas'] as Map?)?['nombre'];
      final donde = mesa != null ? 'Mesa $mesa' : 'Llevar · ${pedido['nombre_llevar'] ?? ''}';
      final cant = (r['cantidad'] as num?)?.toStringAsFixed(0) ?? '';
      SystemSound.play(SystemSoundType.alert);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 12),
        backgroundColor: C.verde,
        content: Row(children: [
          const Icon(Icons.room_service, color: Colors.white),
          const SizedBox(width: 12),
          Expanded(
            child: Text('$donde · listo para servir: $cant× ${r['descripcion']}',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ]),
        action: SnackBarAction(
          label: 'SERVIDO',
          textColor: Colors.white,
          onPressed: () => supabase.from('pedido_detalle').update({'estado_cocina': 'servido'}).eq('id', id),
        ),
      ));
    } catch (_) {
      // Un aviso perdido no debe romper la pantalla
    }
  }

  @override
  void dispose() {
    if (_canal != null) supabase.removeChannel(_canal!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
