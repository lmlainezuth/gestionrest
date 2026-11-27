/// Celda de texto libre para los CSV (separador ;) que se abren en Excel.
///
/// Texto que empieza por = + - @ (o tabulador o retorno) se tomaría por una fórmula: se le antepone
/// un apóstrofo. Con ; comillas o saltos de línea va entre comillas, para que no invente columnas
/// ni filas. Solo para texto que escribe el personal (platos, nombres, proveedores), no para importes.
String celdaCsv(Object? v) {
  var s = v?.toString() ?? '';
  if (RegExp(r'^[=+\-@\t\r]').hasMatch(s)) s = "'$s";
  return RegExp('[";\\n\\r\\t]').hasMatch(s) ? '"${s.replaceAll('"', '""')}"' : s;
}
