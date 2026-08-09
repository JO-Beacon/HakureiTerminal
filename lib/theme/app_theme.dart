import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../services/system_fonts.dart';

const String themePrimaryColorKey = '主色';
const String themeAccentColorKey = '强调色';
const String themeBackgroundColorKey = '背景色';
const String themeSurfaceColorKey = '表面色';
const String themeTextColorKey = '文字颜色';
const String themeSecondaryTextColorKey = '次要文字颜色';
const String themeBorderColorKey = '边框颜色';

const List<String> appThemeColorKeys = <String>[
  themePrimaryColorKey,
  themeAccentColorKey,
  themeBackgroundColorKey,
  themeSurfaceColorKey,
  themeTextColorKey,
  themeSecondaryTextColorKey,
  themeBorderColorKey,
];

class AppThemePalette {
  const AppThemePalette({
    required this.id,
    required this.name,
    required this.brightness,
    required this.isPreset,
    required this.colors,
  });

  final String id;
  final String name;
  final Brightness brightness;
  final bool isPreset;
  final Map<String, Color> colors;

  Color get primary => colors[themePrimaryColorKey]!;
  Color get accent => colors[themeAccentColorKey]!;
  Color get background => colors[themeBackgroundColorKey]!;
  Color get surface => colors[themeSurfaceColorKey]!;
  Color get text => colors[themeTextColorKey]!;
  Color get secondaryText => colors[themeSecondaryTextColorKey]!;
  Color get border => colors[themeBorderColorKey]!;

  AppThemePalette copyWith({String? name, Map<String, Color>? colors}) {
    final nextColors = colors ?? this.colors;
    return AppThemePalette(
      id: id,
      name: name ?? this.name,
      brightness: colors == null
          ? brightness
          : ThemeData.estimateBrightnessForColor(
              nextColors[themeBackgroundColorKey]!,
            ),
      isPreset: isPreset,
      colors: nextColors,
    );
  }

  CustomThemeSettings toSettings() {
    return CustomThemeSettings(
      id: id,
      name: name,
      colors: <String, String>{
        for (final entry in colors.entries)
          entry.key: colorToSettingsHex(entry.value),
      },
    );
  }

  static AppThemePalette? fromSettings(CustomThemeSettings settings) {
    final colors = <String, Color>{};
    for (final key in appThemeColorKeys) {
      final color = colorFromSettingsHex(settings.colors[key]);
      if (color == null) {
        return null;
      }
      colors[key] = color;
    }
    final background = colors[themeBackgroundColorKey]!;
    return AppThemePalette(
      id: settings.id,
      name: settings.name,
      brightness: ThemeData.estimateBrightnessForColor(background),
      isPreset: false,
      colors: colors,
    );
  }
}

AppThemePalette _presetTheme({
  required String id,
  required String name,
  required Brightness brightness,
  required List<Color> colors,
}) {
  return AppThemePalette(
    id: id,
    name: name,
    brightness: brightness,
    isPreset: true,
    colors: <String, Color>{
      for (var i = 0; i < appThemeColorKeys.length; i++)
        appThemeColorKeys[i]: colors[i],
    },
  );
}

final List<AppThemePalette> appPresetLightThemes = <AppThemePalette>[
  _presetTheme(
    id: 'preset_sakura_light',
    name: '樱红',
    brightness: Brightness.light,
    colors: const <Color>[
      Color(0xffa61e3c),
      Color(0xff6f557d),
      Color(0xfffff8f9),
      Color(0xffffffff),
      Color(0xff25191c),
      Color(0xff725d62),
      Color(0xffdec7cc),
    ],
  ),
  _presetTheme(
    id: 'preset_indigo_light',
    name: '晴蓝',
    brightness: Brightness.light,
    colors: const <Color>[
      Color(0xff315a9b),
      Color(0xff2d7f82),
      Color(0xfff5f8fc),
      Color(0xffffffff),
      Color(0xff172033),
      Color(0xff5b6678),
      Color(0xffc7d2e2),
    ],
  ),
  _presetTheme(
    id: 'preset_forest_light',
    name: '青岚',
    brightness: Brightness.light,
    colors: const <Color>[
      Color(0xff256b52),
      Color(0xff8a5d26),
      Color(0xfff5faf7),
      Color(0xffffffff),
      Color(0xff17251f),
      Color(0xff5a6d64),
      Color(0xffc4d8ce),
    ],
  ),
  _presetTheme(
    id: 'preset_amber_light',
    name: '金桂',
    brightness: Brightness.light,
    colors: const <Color>[
      Color(0xff966018),
      Color(0xff9b3f4f),
      Color(0xfffffaf2),
      Color(0xffffffff),
      Color(0xff2a2116),
      Color(0xff746653),
      Color(0xffdfd0b8),
    ],
  ),
  _presetTheme(
    id: 'preset_graphite_light',
    name: '墨纸',
    brightness: Brightness.light,
    colors: const <Color>[
      Color(0xff3f545d),
      Color(0xff8b4f5d),
      Color(0xfff4f6f7),
      Color(0xffffffff),
      Color(0xff182024),
      Color(0xff5e6a70),
      Color(0xffc9d1d5),
    ],
  ),
];

final List<AppThemePalette> appPresetDarkThemes = <AppThemePalette>[
  _presetTheme(
    id: 'preset_sakura_dark',
    name: '夜樱',
    brightness: Brightness.dark,
    colors: const <Color>[
      Color(0xffff9caf),
      Color(0xffc7a6d8),
      Color(0xff171214),
      Color(0xff21191c),
      Color(0xfff4e8eb),
      Color(0xffbea7ad),
      Color(0xff513840),
    ],
  ),
  _presetTheme(
    id: 'preset_indigo_dark',
    name: '深海',
    brightness: Brightness.dark,
    colors: const <Color>[
      Color(0xff9dbcf2),
      Color(0xff75c7c9),
      Color(0xff111722),
      Color(0xff192230),
      Color(0xffe8edf6),
      Color(0xffa6b1c3),
      Color(0xff37465c),
    ],
  ),
  _presetTheme(
    id: 'preset_forest_dark',
    name: '松影',
    brightness: Brightness.dark,
    colors: const <Color>[
      Color(0xff87d8b4),
      Color(0xffe0b274),
      Color(0xff101814),
      Color(0xff18231e),
      Color(0xffe5f0ea),
      Color(0xff9fb5aa),
      Color(0xff344b40),
    ],
  ),
  _presetTheme(
    id: 'preset_amber_dark',
    name: '琥珀夜',
    brightness: Brightness.dark,
    colors: const <Color>[
      Color(0xffefbd72),
      Color(0xffe58c9e),
      Color(0xff19150f),
      Color(0xff241e16),
      Color(0xfff3eadc),
      Color(0xffb9aa94),
      Color(0xff51432f),
    ],
  ),
  _presetTheme(
    id: 'preset_graphite_dark',
    name: '炭墨',
    brightness: Brightness.dark,
    colors: const <Color>[
      Color(0xffa8c4cf),
      Color(0xffd7a0ad),
      Color(0xff121719),
      Color(0xff1c2327),
      Color(0xffe8edef),
      Color(0xffa3afb4),
      Color(0xff3a494f),
    ],
  ),
];

final List<AppThemePalette> appPresetThemes = <AppThemePalette>[
  ...appPresetLightThemes,
  ...appPresetDarkThemes,
];

List<AppThemePalette> customThemePalettes(AppearanceSettings appearance) {
  return appearance.customThemes
      .map(AppThemePalette.fromSettings)
      .whereType<AppThemePalette>()
      .toList(growable: false);
}

AppThemePalette resolveAppTheme(AppearanceSettings appearance) {
  final palettes = <AppThemePalette>[
    ...appPresetThemes,
    ...customThemePalettes(appearance),
  ];
  return palettes.firstWhere(
    (theme) => theme.id == appearance.themeId,
    orElse: () => appPresetDarkThemes.first,
  );
}

String defaultThemeIdForPlatformBrightness(Brightness? brightness) {
  return brightness == Brightness.light
      ? 'preset_sakura_light'
      : 'preset_sakura_dark';
}

String colorToSettingsHex(Color color) {
  return '#${color.toARGB32().toRadixString(16).padLeft(8, '0')}';
}

Color? colorFromSettingsHex(String? value) {
  if (value == null) {
    return null;
  }
  var hex = value.trim().toLowerCase();
  if (hex.startsWith('#')) {
    hex = hex.substring(1);
  }
  if (hex.length == 6) {
    hex = 'ff$hex';
  }
  if (hex.length != 8) {
    return null;
  }
  final parsed = int.tryParse(hex, radix: 16);
  return parsed == null ? null : Color(parsed);
}

ThemeData buildAppTheme(
  AppThemePalette palette, {
  String fontFamilyId = AppearanceSettings.defaultFontFamilyId,
  double fontSize = AppearanceSettings.defaultFontSize,
  String uiDensity = AppearanceSettings.defaultUiDensity,
  double cornerRadius = AppearanceSettings.defaultCornerRadius,
}) {
  final radius = BorderRadius.all(Radius.circular(cornerRadius));
  final shape = RoundedRectangleBorder(borderRadius: radius);
  final buttonShape = WidgetStatePropertyAll<OutlinedBorder>(shape);
  final dark = palette.brightness == Brightness.dark;
  final primaryContainer = _blend(
    palette.background,
    palette.primary,
    dark ? 0.28 : 0.13,
  );
  final secondaryContainer = _blend(
    palette.background,
    palette.accent,
    dark ? 0.24 : 0.12,
  );
  final surfaceContainerLow = _blend(
    palette.background,
    palette.surface,
    dark ? 0.48 : 0.72,
  );
  final surfaceContainer = _blend(
    palette.background,
    palette.surface,
    dark ? 0.68 : 0.88,
  );
  final surfaceContainerHigh = _blend(
    palette.surface,
    palette.primary,
    dark ? 0.10 : 0.045,
  );
  final baseScheme = ColorScheme.fromSeed(
    seedColor: palette.primary,
    brightness: palette.brightness,
  );
  final scheme = baseScheme.copyWith(
    primary: palette.primary,
    onPrimary: _contrastingText(palette.primary),
    primaryContainer: primaryContainer,
    onPrimaryContainer: palette.text,
    secondary: palette.accent,
    onSecondary: _contrastingText(palette.accent),
    secondaryContainer: secondaryContainer,
    onSecondaryContainer: palette.text,
    surface: palette.surface,
    onSurface: palette.text,
    onSurfaceVariant: palette.secondaryText,
    outline: palette.border,
    outlineVariant: _blend(palette.background, palette.border, 0.62),
    surfaceContainerLowest: palette.background,
    surfaceContainerLow: surfaceContainerLow,
    surfaceContainer: surfaceContainer,
    surfaceContainerHigh: surfaceContainerHigh,
    surfaceContainerHighest: _blend(
      palette.surface,
      palette.primary,
      dark ? 0.16 : 0.075,
    ),
  );
  final theme = ThemeData(
    brightness: palette.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.background,
    canvasColor: palette.background,
    useMaterial3: true,
    visualDensity: switch (uiDensity) {
      'comfortable' => const VisualDensity(horizontal: 1, vertical: 1),
      'compact' => const VisualDensity(horizontal: -1, vertical: -1),
      _ => VisualDensity.standard,
    },
    fontFamily: appFontFamily(fontFamilyId),
    fontFamilyFallback: _fontFallback(),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      foregroundColor: palette.text,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      shape: shape,
      color: surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: palette.border),
    chipTheme: ChipThemeData(shape: shape),
    dialogTheme: DialogThemeData(
      shape: shape,
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      shape: shape,
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(shape: shape),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(shape: buttonShape),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: radius),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(shape: buttonShape),
    ),
    checkboxTheme: CheckboxThemeData(shape: shape),
    listTileTheme: ListTileThemeData(shape: shape),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      borderRadius: BorderRadius.zero,
    ),
    // 2024 版 M3 滑杆使用条状手柄，符合全局去圆形规范。
    // ignore: deprecated_member_use
    sliderTheme: const SliderThemeData(year2023: false),
  );
  final fontSizeFactor = fontSize / AppearanceSettings.defaultFontSize;
  return theme.copyWith(
    textTheme: _scaleTextTheme(theme.textTheme, fontSizeFactor),
    primaryTextTheme: _scaleTextTheme(theme.primaryTextTheme, fontSizeFactor),
  );
}

TextTheme _scaleTextTheme(TextTheme textTheme, double factor) {
  TextStyle scale(TextStyle? style, double fallbackSize) {
    final source = style ?? const TextStyle();
    return source.copyWith(
      fontSize: (source.fontSize ?? fallbackSize) * factor,
    );
  }

  return textTheme.copyWith(
    displayLarge: scale(textTheme.displayLarge, 57),
    displayMedium: scale(textTheme.displayMedium, 45),
    displaySmall: scale(textTheme.displaySmall, 36),
    headlineLarge: scale(textTheme.headlineLarge, 32),
    headlineMedium: scale(textTheme.headlineMedium, 28),
    headlineSmall: scale(textTheme.headlineSmall, 24),
    titleLarge: scale(textTheme.titleLarge, 22),
    titleMedium: scale(textTheme.titleMedium, 16),
    titleSmall: scale(textTheme.titleSmall, 14),
    bodyLarge: scale(textTheme.bodyLarge, 16),
    bodyMedium: scale(textTheme.bodyMedium, 14),
    bodySmall: scale(textTheme.bodySmall, 12),
    labelLarge: scale(textTheme.labelLarge, 14),
    labelMedium: scale(textTheme.labelMedium, 12),
    labelSmall: scale(textTheme.labelSmall, 11),
  );
}

String? appFontFamily(String fontFamilyId) {
  return switch (fontFamilyId) {
    'system' => systemUiFontFamily(),
    'source_han_serif_sc' => 'Source Han Serif SC',
    'lxgw_wenkai' => 'LXGW WenKai',
    'jetbrains_mono' => 'JetBrains Mono',
    _ => 'SourceHanSansSC',
  };
}

Color _blend(Color base, Color overlay, double opacity) {
  return Color.alphaBlend(overlay.withValues(alpha: opacity), base);
}

Color _contrastingText(Color background) {
  return ThemeData.estimateBrightnessForColor(background) == Brightness.dark
      ? Colors.white
      : Colors.black;
}

List<String>? _fontFallback() {
  final systemFamily = systemUiFontFamily();
  final fallbacks = systemUiFontFallback() ?? const <String>[];
  return <String>{
    if (systemFamily != null && systemFamily.isNotEmpty) systemFamily,
    ...fallbacks,
  }.toList(growable: false);
}
