import 'package:flutter/material.dart';

import '../../core/panel_lateral.dart';
import '../../core/tema.dart';
import '../../main.dart';
import '../carta/colores.dart' show leerImporte;
import '../ticketbai/modelos.dart' show euros;
import 'comun.dart';

const _diasSemana = ['Lunes', 'Martes', 'Miércoles', 'Jueves', 'Viernes', 'Sábado', 'Domingo'];

String _diaLargo(String isoFecha) {
  final d = DateTime.parse(isoFecha);
  return '${_diasSemana[d.weekday - 1]} ${d.day} ${meses[d.month - 1].substring(0, 3)}';
}

/// Caja de cada día: lo vendido en efectivo y con tarjeta.
class CajaDiariaPage extends StatefulWidget {
  const CajaDiariaPage({super.key});

  @override
  State<CajaDiariaPage> createState() => _CajaDiariaPageState();
}

class _CajaDiariaPageState extends State<CajaDiariaPage> {
  DateTime _mes = DateTime.now();
  List<Map<String, dynamic>> _cajas = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final (desde, hasta) = rangoMes(_mes);
    _cajas = List<Map<String, dynamic>>.from(await supabase
        .from('cajas_diarias')
        .select()
        .gte('fecha', desde)
        .lte('fecha', hasta)
        .order('fecha', ascending: false));
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _editar([Map<String, dynamic>? c]) async {
    final r = await mostrarPanel<Map<String, dynamic>>(context, (_) => _PanelCaja(caja: c));
    if (r == null) return;
    try {
      if (r['_borrar'] == true) {
        await supabase.from('cajas_diarias').delete().eq('id', c!['id']);
      } else {
        await supabase.from('cajas_diarias').upsert(r, onConflict: 'empresa_id,fecha');
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final total = _cajas.fold(0.0, (s, c) => s + (c['total'] as num).toDouble());
    final efectivo = _cajas.fold(0.0, (s, c) => s + ((c['efectivo'] as num?) ?? 0).toDouble());
    final tarjeta = _cajas.fold(0.0, (s, c) => s + ((c['tarjeta'] as num?) ?? 0).toDouble());
    final dias = _cajas.where((c) => (c['total'] as num) > 0).length;
    final mejor = _cajas.isEmpty ? null : _cajas.reduce((a, b) => (a['total'] as num) >= (b['total'] as num) ? a : b);
    final hoy = iso(DateTime.now());
    final hayHoy = _cajas.any((c) => c['fecha'] == hoy);
    final ancho = MediaQuery.sizeOf(context).width;
    return ListView(
      padding: EdgeInsets.all(ancho < 600 ? 14 : 28),
      children: [
        Row(children: [
          SelectorMes(mes: _mes, onCambio: (m) {
            _mes = m;
            _cargar();
          }),
          const Spacer(),
          FilledButton.icon(
            onPressed: () => _editar(hayHoy ? _cajas.firstWhere((c) => c['fecha'] == hoy) : null),
            icon: Icon(hayHoy ? Icons.edit_outlined : Icons.add),
            label: Text(hayHoy ? 'Caja de hoy' : 'Registrar caja de hoy'),
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16)),
          ),
        ]),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          decoration: BoxDecoration(color: C.verde, borderRadius: BorderRadius.circular(18)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Vendido este mes', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 4),
                Text(euros(total), style: titulo(34, color: Colors.white)),
                const SizedBox(height: 4),
                Text(
                  '$dias ${dias == 1 ? 'día' : 'días'} · media ${euros(dias == 0 ? 0 : total / dias)}/día'
                  '${efectivo + tarjeta > 0 ? ' · efectivo ${euros(efectivo)} · tarjeta ${euros(tarjeta)}' : ''}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ]),
            ),
            const Icon(Icons.point_of_sale, color: Colors.white, size: 34),
          ]),
        ),
        const SizedBox(height: 16),
        if (_cargando) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_cargando && _cajas.isEmpty)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Center(child: Text('No hay cajas registradas este mes.', style: TextStyle(color: C.gris))),
          ),
        for (final c in _cajas)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TarjetaFila(
              onTap: () => _editar(c),
              child: Row(children: [
                IconoFila(c == mejor ? Icons.emoji_events_outlined : Icons.calendar_today_outlined,
                    c == mejor ? C.naranja : C.verde),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_diaLargo(c['fecha'] as String), style: titulo(17)),
                    Text(
                      c['efectivo'] == null && c['tarjeta'] == null
                          ? (c['notas'] as String?) ?? 'Sin desglose'
                          : 'Efectivo ${euros((c['efectivo'] as num?) ?? 0)} · Tarjeta ${euros((c['tarjeta'] as num?) ?? 0)}'
                              '${c['notas'] != null ? ' · ${c['notas']}' : ''}',
                      style: const TextStyle(color: C.gris, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(euros(c['total'] as num), style: titulo(18)),
                  const SizedBox(height: 4),
                  c['estado'] == 'pendiente'
                      ? const EtiquetaEstado('Por revisar', aviso: true)
                      : EtiquetaEstado(c == mejor ? 'Mejor día' : 'Cerrada', aviso: false),
                ]),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, color: C.gris),
              ]),
            ),
          ),
      ],
    );
  }
}

class _PanelCaja extends StatefulWidget {
  const _PanelCaja({required this.caja});
  final Map<String, dynamic>? caja;

  @override
  State<_PanelCaja> createState() => _PanelCajaState();
}

class _PanelCajaState extends State<_PanelCaja> {
  late final c = widget.caja;
  late DateTime _fecha = c == null ? DateTime.now() : DateTime.parse(c!['fecha'] as String);
  static String _f(num? v) => v == null ? '' : v.toStringAsFixed(2).replaceAll('.', ',');
  late final _efectivo = TextEditingController(text: _f(c?['efectivo'] as num?));
  late final _tarjeta = TextEditingController(text: _f(c?['tarjeta'] as num?));
  late final _total = TextEditingController(text: _f(c?['total'] as num?));
  late final _notas = TextEditingController(text: c?['notas'] as String?);
  late String _estado = (c?['estado'] as String?) ?? 'cerrada';
  bool _trayendo = false;
  String? _error;

  bool get _conDesglose => leerImporte(_efectivo.text) != null || leerImporte(_tarjeta.text) != null;
  double get _totalCalculado =>
      _conDesglose ? (leerImporte(_efectivo.text) ?? 0) + (leerImporte(_tarjeta.text) ?? 0) : (leerImporte(_total.text) ?? 0);

  /// Suma lo cobrado en el TPV ese día por forma de pago (Bizum va con tarjeta).
  Future<void> _traerTpv() async {
    setState(() => _trayendo = true);
    try {
      final ini = DateTime(_fecha.year, _fecha.month, _fecha.day).toUtc().toIso8601String();
      final fin = DateTime(_fecha.year, _fecha.month, _fecha.day + 1).toUtc().toIso8601String();
      final pagos = await supabase.from('pagos').select('metodo, importe').gte('creado_en', ini).lt('creado_en', fin);
      var e = 0.0, t = 0.0;
      for (final p in pagos) {
        final v = (p['importe'] as num).toDouble();
        p['metodo'] == 'efectivo' ? e += v : t += v;
      }
      setState(() {
        _efectivo.text = _f(e);
        _tarjeta.text = _f(t);
        if (e + t == 0) _error = 'Ese día no hay cobros en el TPV.';
      });
    } catch (e) {
      setState(() => _error = 'No se pudo leer el TPV: $e');
    }
    if (mounted) setState(() => _trayendo = false);
  }

  void _guardar() {
    final total = _totalCalculado;
    if (total <= 0) {
      setState(() => _error = 'Escribe el efectivo y la tarjeta, o el total del día');
      return;
    }
    Navigator.pop(context, {
      'fecha': iso(_fecha),
      'efectivo': leerImporte(_efectivo.text),
      'tarjeta': leerImporte(_tarjeta.text),
      'total': total,
      'estado': _estado,
      'notas': _notas.text.trim().isEmpty ? null : _notas.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) => PanelLateral(
        encabezado: c == null ? 'Caja del día' : 'Caja · ${_diaLargo(c!['fecha'] as String)}',
        boton: 'Guardar caja',
        onBoton: _guardar,
        onBorrar: c == null ? null : () => Navigator.pop(context, {'_borrar': true}),
        textoBorrar: 'Borrar esta caja',
        cuerpo: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const EtiquetaCampo('Fecha'),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              alignment: Alignment.centerLeft,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: c != null
                ? null
                : () async {
                    final d = await showDatePicker(context: context, initialDate: _fecha, firstDate: DateTime(2023), lastDate: DateTime.now());
                    if (d != null) setState(() => _fecha = d);
                  },
            icon: const Icon(Icons.calendar_today_outlined, size: 18),
            label: Text(_diaLargo(iso(_fecha))),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _trayendo ? null : _traerTpv,
            icon: const Icon(Icons.download_outlined),
            label: Text(_trayendo ? 'Leyendo el TPV…' : 'Traer lo cobrado en el TPV ese día'),
          ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const EtiquetaCampo('Efectivo'),
                TextField(
                  controller: _efectivo,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: '0,00', suffixText: '€'),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const EtiquetaCampo('Tarjeta y Bizum'),
                TextField(
                  controller: _tarjeta,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(hintText: '0,00', suffixText: '€'),
                ),
              ]),
            ),
          ]),
          if (!_conDesglose) ...[
            const EtiquetaCampo('O solo el total del día'),
            TextField(
              controller: _total,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(hintText: 'Si no tienes el desglose', suffixText: '€'),
            ),
          ],
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: C.crema, borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              const Text('Total del día', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(euros(_totalCalculado), style: titulo(26, color: C.verde)),
            ]),
          ),
          const EtiquetaCampo('Estado'),
          Segmentos(
            opciones: const {'cerrada': 'Cerrada', 'pendiente': 'Por revisar'},
            actual: _estado,
            onCambio: (v) => setState(() => _estado = v),
          ),
          const EtiquetaCampo('Notas'),
          TextField(controller: _notas, maxLines: 2, decoration: const InputDecoration(hintText: 'Descuadre, incidencias…')),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFFB3261E), fontWeight: FontWeight.w600)),
          ],
        ]),
      );
}
