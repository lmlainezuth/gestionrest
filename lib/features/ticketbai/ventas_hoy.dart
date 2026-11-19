import 'package:flutter/material.dart';

import '../../core/impresion.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../auth/perfil.dart';
import 'modelos.dart' show euros;
import 'ticket_view.dart';

/// Ventas de hoy: para imprimir el ticket cuando el cliente lo pide después de cobrar.
Future<void> mostrarVentasHoy(BuildContext context) => showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Cerrar',
      pageBuilder: (_, __, ___) => const _VentasHoy(),
    );

class _VentasHoy extends StatefulWidget {
  const _VentasHoy();
  @override
  State<_VentasHoy> createState() => _VentasHoyState();
}

class _VentasHoyState extends State<_VentasHoy> {
  List<Map<String, dynamic>>? _ventas;
  Set<String> _anuladas = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final hoy = DateTime.now();
      final desde = DateTime(hoy.year, hoy.month, hoy.day).toUtc().toIso8601String();
      final v = List<Map<String, dynamic>>.from(await supabase
          .from('facturas')
          .select()
          .gte('fecha', desde)
          .order('fecha', ascending: false)
          .limit(300));
      final ids = v.map((f) => f['id']).toList();
      final an = ids.isEmpty
          ? const []
          : await supabase.from('tbai_anulaciones').select('factura_id').inFilter('factura_id', ids);
      setState(() {
        _ventas = v;
        _anuladas = {for (final a in an) a['factura_id'] as String};
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'No se pudieron cargar las ventas (¿hay internet?)');
    }
  }

  String _hora(String iso) {
    final d = DateTime.parse(iso).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _resumen(Map<String, dynamic> f) {
    final l = (f['lineas'] as List?) ?? const [];
    return l
        .map((x) => '${((x['cantidad'] as num?) ?? 1).toStringAsFixed(0)} ${x['descripcion']}')
        .join(', ');
  }

  /// Importes y total del día: solo con el permiso 'total_dia' (el resto solo reimprime).
  bool get _verImportes => Perfil.cache?.puede('total_dia') ?? false;

  /// Total del día (sin anuladas; las devoluciones restan). Solo con el permiso 'total_dia'.
  Widget _total() {
    // Un ticket sustituido por factura con NIF no se cuenta dos veces
    final sustituidos = {for (final f in _ventas!) if (f['sustituye_simplificada'] == true) f['rectifica_id']};
    final validas =
        _ventas!.where((f) => !_anuladas.contains(f['id']) && !sustituidos.contains(f['id'])).toList();
    final total = validas.fold<double>(0, (s, f) => s + (f['importe_total'] as num).toDouble());
    return Container(
      color: const Color(0xFFEAF3EF),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Vendido hoy', style: TextStyle(color: C.gris)),
          Text('${validas.length} ventas', style: const TextStyle(color: C.gris, fontSize: 13)),
        ]),
        const Spacer(),
        Text(euros(total), style: titulo(26, color: C.verde)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ancho = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: C.blanco,
        child: SizedBox(
          width: ancho < 600 ? ancho : 480,
          height: double.infinity,
          child: SafeArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                child: Row(children: [
                  Text('Ventas de hoy', style: titulo(22)),
                  const Spacer(),
                  IconButton(tooltip: 'Actualizar', onPressed: _cargar, icon: const Icon(Icons.refresh)),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                ]),
              ),
              if (_ventas != null && _ventas!.isNotEmpty && _verImportes) _total(),
              const Divider(height: 1),
              Expanded(
                child: _error != null
                    ? Center(child: Text(_error!, style: const TextStyle(color: C.gris)))
                    : _ventas == null
                        ? const Center(child: CircularProgressIndicator())
                        : _ventas!.isEmpty
                            ? const Center(child: Text('Todavía no hay ventas hoy', style: TextStyle(color: C.gris)))
                            : ListView.separated(
                                itemCount: _ventas!.length,
                                separatorBuilder: (_, __) => const Divider(height: 1),
                                itemBuilder: (_, i) {
                                  final f = _ventas![i];
                                  final anulada = _anuladas.contains(f['id']);
                                  final txt = TextStyle(
                                    decoration: anulada ? TextDecoration.lineThrough : null,
                                    color: anulada ? C.gris : null,
                                  );
                                  return ListTile(
                                    title: Text(
                                      _verImportes
                                          ? '${_hora(f['fecha'] as String)} · ${euros(f['importe_total'] as num)} · ${f['serie']}-${f['numero']}'
                                          : '${_hora(f['fecha'] as String)} · ${f['serie']}-${f['numero']}',
                                      style: txt.copyWith(fontWeight: FontWeight.w600),
                                    ),
                                    subtitle: Text(
                                      anulada ? 'Anulada' : _resumen(f),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    // El ticket en pantalla lleva importes: solo para quien puede verlos
                                    onTap: _verImportes ? () => mostrarTicket(context, f, imprimirAuto: false) : null,
                                    trailing: anulada
                                        ? null
                                        : FilledButton.tonalIcon(
                                            onPressed: () {
                                              Impresion.imprimirTicket(f).catchError((e) {
                                                if (context.mounted) {
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                      SnackBar(content: Text('No se pudo imprimir: $e')));
                                                }
                                              });
                                            },
                                            icon: const Icon(Icons.print_outlined),
                                            label: const Text('Imprimir'),
                                          ),
                                  );
                                },
                              ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
