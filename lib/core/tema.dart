import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Colores de la propuesta de diseño de GestiónRest.
class C {
  static const crema = Color(0xFFF6F4EF);
  static const tinta = Color(0xFF1C1B19);
  static const gris = Color(0xFF5E5A52);
  static const borde = Color(0xFFE6E1D6);
  static const bordeFuerte = Color(0xFFD9D4C8);
  static const verde = Color(0xFF0F5C4D);
  static const naranja = Color(0xFFE8742A);
  static const ocupada = Color(0xFFF7C9A6);
  static const reserva = Color(0xFF2F6DB5);
  static const blanco = Colors.white;
}

/// Títulos y cifras en Space Grotesk.
TextStyle titulo(double size, {Color color = C.tinta, FontWeight peso = FontWeight.w700}) =>
    GoogleFonts.spaceGrotesk(fontSize: size, fontWeight: peso, color: color);

ThemeData temaGestionRest() {
  final base = ThemeData(useMaterial3: true, brightness: Brightness.light);
  final esquema = ColorScheme.fromSeed(seedColor: C.verde).copyWith(
    primary: C.verde,
    onPrimary: C.blanco,
    secondary: C.naranja,
    surface: C.crema,
    onSurface: C.tinta,
    secondaryContainer: const Color(0xFFE3EEEA),
    error: const Color(0xFFB3261E),
  );
  final radio12 = BorderRadius.circular(12);
  final radio14 = BorderRadius.circular(14);

  return base.copyWith(
    colorScheme: esquema,
    scaffoldBackgroundColor: C.crema,
    textTheme: base.textTheme.apply(
      fontFamily: GoogleFonts.inter().fontFamily,
      bodyColor: C.tinta,
      displayColor: C.tinta,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: C.crema,
      foregroundColor: C.tinta,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: titulo(22),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.verde,
        foregroundColor: C.blanco,
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: radio14),
        textStyle: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.tinta,
        minimumSize: const Size(0, 48),
        side: const BorderSide(color: C.bordeFuerte),
        shape: RoundedRectangleBorder(borderRadius: radio12),
        textStyle: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: C.verde,
        textStyle: GoogleFonts.inter(fontWeight: FontWeight.w600),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: C.tinta,
      foregroundColor: C.blanco,
      shape: RoundedRectangleBorder(borderRadius: radio14),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.blanco,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      border: OutlineInputBorder(borderRadius: radio12, borderSide: const BorderSide(color: C.bordeFuerte)),
      enabledBorder: OutlineInputBorder(borderRadius: radio12, borderSide: const BorderSide(color: C.bordeFuerte)),
      focusedBorder: OutlineInputBorder(borderRadius: radio12, borderSide: const BorderSide(color: C.verde, width: 2)),
      labelStyle: const TextStyle(color: C.gris),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: C.blanco,
      selectedColor: C.tinta,
      checkmarkColor: C.blanco,
      side: const BorderSide(color: C.bordeFuerte),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      labelStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, color: C.tinta),
      secondaryLabelStyle: GoogleFonts.inter(fontWeight: FontWeight.w600, color: C.blanco),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: C.blanco,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      titleTextStyle: titulo(22),
    ),
    listTileTheme: ListTileThemeData(
      shape: RoundedRectangleBorder(borderRadius: radio12),
      selectedColor: C.tinta,
      selectedTileColor: const Color(0xFFE3EEEA),
    ),
    dividerTheme: const DividerThemeData(color: C.borde, thickness: 1),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.tinta,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: radio12),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.blanco : null),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.verde : null),
    ),
  );
}
