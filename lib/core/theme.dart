import 'package:flutter/material.dart';

/// Charte « ABM » sobre et professionnelle : fond clair, cartes blanches, vert de l'association
/// (logo) comme couleur principale et or en touche discrète. Les couleurs vives ne servent
/// QU'aux statuts (vert = ok, ambre = attention, rouge = erreur).
const accent = Color(0xFF1E6B3A); // vert ABM : boutons, éléments sélectionnés
const accentDeep = Color(0xFF14482A); // vert profond : barre latérale, en-têtes
const accentSoft = Color(0xFF2E7D4F); // vert lisible sur fond clair (textes d'accent)
const gold = Color(0xFFC9A227); // or du logo : filets, repères

const okColor = Color(0xFF2E9E6A);
const warnColor = Color(0xFFD08A12);
const errColor = Color(0xFFD64545);

const inkBase = Color(0xFFF4F6F3); // fond de page
const panelSolid = Colors.white; // cartes, dialogues
const surfaceAlt = Color(0xFFF0F3EF); // champs, zones secondaires
const lineColor = Color(0xFFDDE3DC); // bordures et séparateurs
const textStrong = Color(0xFF17251C);
const textMuted = Color(0xFF5B6A61);
const textFaint = Color(0xFF8F9A93);

const brandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF247A44), accentDeep],
);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.light,
  ).copyWith(
    primary: accent,
    onPrimary: Colors.white,
    secondary: gold,
    tertiary: accentSoft,
    surface: panelSolid,
    onSurface: textStrong,
    error: errColor,
    outline: const Color(0xFFB9C3BC),
    outlineVariant: lineColor,
  );

  const radius = 12.0;
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: Brightness.light);

  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: panelSolid,
    textTheme: base.textTheme.apply(bodyColor: textStrong, displayColor: textStrong),
    iconTheme: const IconThemeData(color: textMuted),
    appBarTheme: const AppBarTheme(
      backgroundColor: panelSolid,
      foregroundColor: textStrong,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0.5,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: textStrong),
      iconTheme: IconThemeData(color: textStrong),
    ),
    dividerTheme: const DividerThemeData(color: lineColor, space: 1),
    listTileTheme: const ListTileThemeData(
      iconColor: textMuted,
      textColor: textStrong,
      subtitleTextStyle: TextStyle(color: textMuted, fontSize: 13),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: panelSolid,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: lineColor),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: panelSolid,
      modalBackgroundColor: panelSolid,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: textStrong,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: panelSolid,
      labelStyle: const TextStyle(color: textMuted),
      helperStyle: const TextStyle(color: textMuted),
      hintStyle: const TextStyle(color: textFaint),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: lineColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: Color(0xFFCCD5CE)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: accent, width: 1.6),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: lineColor),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        backgroundColor: accent,
        foregroundColor: Colors.white,
        disabledBackgroundColor: lineColor,
        disabledForegroundColor: textFaint,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
        textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: accent,
        side: const BorderSide(color: Color(0xFFB9C3BC)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: accent)),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: panelSolid,
      surfaceTintColor: Colors.transparent,
      indicatorColor: accent.withValues(alpha: 0.14),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? accent : textMuted,
          )),
      iconTheme: WidgetStateProperty.resolveWith(
          (s) => IconThemeData(color: s.contains(WidgetState.selected) ? accent : textMuted)),
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: panelSolid),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? okColor : lineColor),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : null),
      side: const BorderSide(color: textMuted, width: 1.4),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      iconColor: textMuted,
      collapsedIconColor: textMuted,
      textColor: textStrong,
      collapsedTextColor: textStrong,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: panelSolid,
      selectedColor: accent.withValues(alpha: 0.14),
      side: const BorderSide(color: lineColor),
      labelStyle: const TextStyle(color: textStrong),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : panelSolid),
        foregroundColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : textStrong),
        side: WidgetStateProperty.all(const BorderSide(color: lineColor)),
      ),
    ),
  );
}
