import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class StudioFont {
  const StudioFont(this.family, this.label);

  final String family;
  final String label;
}

const List<StudioFont> studioFonts = <StudioFont>[
  StudioFont('NotoSans', 'Обычный · Noto Sans'),
  StudioFont('NotoSerif', 'С засечками · Noto Serif'),
  StudioFont('JetBrainsMono', 'Моноширинный · JetBrains Mono'),
  StudioFont('UnifrakturMaguntia', 'Готика · Unifraktur (латиница)'),
  StudioFont('ShantellSans', 'Комикс · Shantell Sans'),
  StudioFont('PressStart2P', 'Пиксельный · Press Start 2P'),
  StudioFont('RubikGlitch', 'Глитч · Rubik Glitch'),
  StudioFont('RubikIso', 'Изометрический · Rubik Iso'),
  StudioFont('RubikMonoOne', 'Массивный · Rubik Mono One'),
  StudioFont('Bungee', 'Вывеска · Bungee (латиница)'),
];

// Missing glyphs use a normal face rather than imitating the selected style.
// CJK uses Korean regional glyph forms; this is not universal Unicode coverage.
const List<String> internationalFontFallback = <String>[
  'NotoSans',
  'NotoSansArabic',
  'NotoSansHebrew',
  'NotoSansDevanagari',
  'NotoSansThai',
  'NotoSansCJK',
];

const Map<String, String> _fontLicenseAssets = <String, String>{
  'Noto Sans': 'assets/fonts/NotoSans/OFL.txt',
  'Noto Serif': 'assets/fonts/NotoSerif/OFL.txt',
  'JetBrains Mono': 'assets/fonts/JetBrainsMono/OFL.txt',
  'UnifrakturMaguntia': 'assets/fonts/UnifrakturMaguntia/OFL.txt',
  'Shantell Sans': 'assets/fonts/ShantellSans/OFL.txt',
  'Press Start 2P': 'assets/fonts/PressStart2P/OFL.txt',
  'Rubik Glitch': 'assets/fonts/RubikGlitch/OFL.txt',
  'Rubik Iso': 'assets/fonts/RubikIso/OFL.txt',
  'Rubik Mono One': 'assets/fonts/RubikMonoOne/OFL.txt',
  'Bungee': 'assets/fonts/Bungee/OFL.txt',
  'Noto Sans Arabic': 'assets/fonts/NotoSansArabic/OFL.txt',
  'Noto Sans Hebrew': 'assets/fonts/NotoSansHebrew/OFL.txt',
  'Noto Sans Devanagari': 'assets/fonts/NotoSansDevanagari/OFL.txt',
  'Noto Sans Thai': 'assets/fonts/NotoSansThai/OFL.txt',
  'Noto Sans CJK KR': 'assets/fonts/NotoSansCJK/OFL.txt',
};

void registerFontLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final entry in _fontLicenseAssets.entries) {
      final text = await rootBundle.loadString(entry.value);
      yield LicenseEntryWithLineBreaks(<String>[entry.key], text);
    }
  });
}
