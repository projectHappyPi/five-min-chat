import 'package:flutter/material.dart';

/// 목업과 같은 색. 기본은 시스템 설정(라이트/다크)을 따른다.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.surface,
    required this.line,
    required this.text,
    required this.muted,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.mine,
    required this.theirs,
    required this.warn,
    required this.onWarn,
    required this.danger,
  });

  final Color bg, surface, line, text, muted, accent, onAccent, accentSoft, mine, theirs, warn, onWarn, danger;

  static const dark = Palette(
    bg: Color(0xFF121316),
    surface: Color(0xFF1C1D21),
    line: Color(0xFF2E3036),
    text: Color(0xFFECECEF),
    muted: Color(0xFFA2A4AD),
    accent: Color(0xFF8FA8FF),
    onAccent: Color(0xFF10152B),
    accentSoft: Color(0xFF232A45),
    mine: Color(0xFF2D3760),
    theirs: Color(0xFF25262B),
    warn: Color(0xFFFFB25C),
    onWarn: Color(0xFF2B1800),
    danger: Color(0xFFFF8A80),
  );

  static const light = Palette(
    bg: Color(0xFFF5F5F2),
    surface: Color(0xFFFFFFFF),
    line: Color(0xFFE4E4DF),
    text: Color(0xFF17181B),
    muted: Color(0xFF5E6068),
    accent: Color(0xFF3553D1),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFECEEF8),
    mine: Color(0xFFDFE5FB),
    theirs: Color(0xFFEFEFEC),
    warn: Color(0xFFA35A00),
    onWarn: Color(0xFFFFFFFF),
    danger: Color(0xFFB3261E),
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) => (t < 0.5 || other is! Palette) ? this : other;
}

extension PaletteX on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>()!;
}

ThemeData buildTheme(Brightness b) {
  final p = b == Brightness.dark ? Palette.dark : Palette.light;
  final scheme = ColorScheme.fromSeed(seedColor: p.accent, brightness: b).copyWith(
    primary: p.accent,
    onPrimary: p.onAccent,
    surface: p.bg,
    onSurface: p.text,
    error: p.danger,
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));
  return ThemeData(
    useMaterial3: true,
    brightness: b,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    dividerColor: p.line,
    extensions: [p],
    appBarTheme: AppBarTheme(backgroundColor: p.bg, foregroundColor: p.text, elevation: 0, scrolledUnderElevation: 0),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.bg,
      indicatorColor: p.accentSoft,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12, color: p.text)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: p.onAccent,
        minimumSize: const Size.fromHeight(54),
        shape: shape,
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        side: BorderSide(color: p.line),
        minimumSize: const Size(44, 48),
        shape: shape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: p.accent, width: 1.5)),
    ),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: p.surface, showDragHandle: true),
    dialogTheme: DialogThemeData(backgroundColor: p.surface),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: p.text, contentTextStyle: TextStyle(color: p.bg)),
  );
}

/// 테마의 채운 버튼은 가로 전체를 채운다. 줄 안이나 대화상자에 넣는 작은 버튼은 이 모양을 쓴다
final ButtonStyle compactButton = FilledButton.styleFrom(minimumSize: const Size(72, 44), padding: const EdgeInsets.symmetric(horizontal: 16));
