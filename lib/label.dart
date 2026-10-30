import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:qr/qr.dart';
import 'raster.dart';
import 'fonts.dart';
import 'image_decode.dart';
import 'media_geometry.dart' as geometry;
import 'media_geometry.dart' show MediaProfile;

enum ElementKind { text, qr, image }

enum TextResizeMode { box, stretch }

const minTextScale = 0.01, maxTextScale = 100.0;

class LabelElement {
  LabelElement({
    required this.kind,
    this.text = '',
    this.x = 12,
    this.y = 12,
    this.width = 160,
    this.height = 40,
    this.rotation = 0,
    this.fontSize = 22,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.aspectLocked = true,
    this.fontFamily = 'NotoSans',
    this.textResizeMode = TextResizeMode.box,
    this.textScaleX = 1,
    this.textScaleY = 1,
    this.imageBytes,
    this.inkOnly = false,
    this.settings = const RasterSettings(),
  });
  final ElementKind kind;
  String text;
  double x, y, width, height, rotation, fontSize;
  bool bold, italic, underline, strikethrough, aspectLocked;
  String fontFamily;
  TextResizeMode textResizeMode;
  double textScaleX, textScaleY;
  Uint8List? imageBytes;
  final bool inkOnly;
  RasterSettings settings;
  ui.Image? image;
  ui.Image? colorImage;
  QrImage? qr;
  Uint8List? _sourceRgba;
  int _sourceWidth = 0, _sourceHeight = 0, _generation = 0;
  int _imageSourceWidth = 0, _imageSourceHeight = 0;
  int get imageSourceWidth => _imageSourceWidth;
  int get imageSourceHeight => _imageSourceHeight;
  bool _disposed = false;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'text': text,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'rotation': rotation,
    'fontSize': fontSize,
    'bold': bold,
    'italic': italic,
    'underline': underline,
    'strikethrough': strikethrough,
    'aspectLocked': aspectLocked,
    'fontFamily': fontFamily,
    'textResizeMode': textResizeMode.name,
    'textScaleX': textScaleX,
    'textScaleY': textScaleY,
    'image': imageBytes == null ? null : base64Encode(imageBytes!),
    'inkOnly': inkOnly,
    'settings': settings.toJson(),
  };
  factory LabelElement.fromJson(Map<String, dynamic> json) => LabelElement(
    kind: ElementKind.values.byName(json['kind'] as String),
    text: json['text'] as String,
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
    rotation: (json['rotation'] as num).toDouble(),
    fontSize: (json['fontSize'] as num).toDouble(),
    bold: json['bold'] as bool,
    italic: json['italic'] as bool,
    underline: json['underline'] as bool,
    strikethrough: json['strikethrough'] as bool,
    aspectLocked: json['aspectLocked'] as bool,
    fontFamily: json['fontFamily'] as String,
    textResizeMode: TextResizeMode.values.byName(
      json['textResizeMode'] as String,
    ),
    textScaleX: (json['textScaleX'] as num).toDouble(),
    textScaleY: (json['textScaleY'] as num).toDouble(),
    imageBytes: json['image'] == null
        ? null
        : base64Decode(json['image'] as String),
    inkOnly: json['inkOnly'] as bool? ?? false,
    settings: RasterSettings.fromJson(
      Map<String, dynamic>.from(json['settings'] as Map),
    ),
  );
  bool contains(Offset point) {
    final delta = point - Offset(x + width / 2, y + height / 2);
    final c = math.cos(-rotation), s = math.sin(-rotation);
    final px = delta.dx * c - delta.dy * s;
    final py = delta.dx * s + delta.dy * c;
    return px.abs() <= width / 2 && py.abs() <= height / 2;
  }

  Future<void> prepare() async {
    final generation = ++_generation;
    if (kind == ElementKind.qr) {
      qr = null;
      qr = QrImage(
        QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M),
      );
    } else if (kind == ElementKind.image && imageBytes != null) {
      if (_sourceRgba == null) {
        final decoded = await decodeLabelImage(
          imageBytes!,
          maxDimension: inkOnly ? 9600 : 512,
          maxPixels: inkOnly ? 16 * 1024 * 1024 : null,
        );
        try {
          final rgba = await decoded.image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          if (rgba == null) {
            throw StateError('Не удалось прочитать изображение');
          }
          if (_disposed || generation != _generation) return;
          colorImage?.dispose();
          colorImage = decoded.image.clone();
          _imageSourceWidth = decoded.sourceWidth;
          _imageSourceHeight = decoded.sourceHeight;
          _sourceWidth = decoded.image.width;
          _sourceHeight = decoded.image.height;
          _sourceRgba = rgba.buffer.asUint8List(
            rgba.offsetInBytes,
            rgba.lengthInBytes,
          );
        } finally {
          decoded.image.dispose();
        }
      }
      if (_disposed || generation != _generation) return;
      final result = monochromeRgba(
        _sourceRgba!,
        _sourceWidth,
        _sourceHeight,
        settings,
      );
      final next = await rgbaImage(result, _sourceWidth, _sourceHeight);
      if (_disposed || generation != _generation) {
        next.dispose();
        return;
      }
      image?.dispose();
      image = next;
    }
  }

  void dispose() {
    _disposed = true;
    ++_generation;
    image?.dispose();
    colorImage?.dispose();
    _sourceRgba = null;
  }
}

class LabelDocument {
  LabelDocument({
    this.name = 'Моя этикетка',
    num lengthMm = 30,
    MediaProfile? media,
    int rows = 1,
    int columns = 1,
    bool trimMargins = false,
    List<LabelElement>? elements,
  }) : _media = media ?? MediaProfile(lengthMm: lengthMm.toDouble()),
       _rows = rows,
       _columns = columns,
       _trimMargins = trimMargins,
       elements = elements ?? [] {
    _validateLayout(_media, rows, columns, trimMargins: trimMargins);
  }
  String name;
  MediaProfile _media;
  int _rows, _columns;
  bool _trimMargins;
  static const int maxCanvasPixels = geometry.maxMediaCanvasPixels;
  static const double maxElementWidth = 9600;
  static const double maxElementHeight = 9600;

  static bool fitsLayout(
    MediaProfile media,
    int rows,
    int columns, {
    bool trimMargins = false,
  }) {
    if (rows < 1 || rows > 8 || columns < 1 || columns > 8) return false;
    if (trimMargins) {
      final safe = media.safeRect;
      return media.isCalibrated &&
          !safe.isEmpty &&
          safe.width.toInt() * safe.height.toInt() * rows * columns <=
              maxCanvasPixels;
    }
    return media.rasterRows * media.paperHeightDots * rows * columns <=
        maxCanvasPixels;
  }

  static void _validateLayout(
    MediaProfile media,
    int rows,
    int columns, {
    bool trimMargins = false,
  }) {
    if (!fitsLayout(media, rows, columns, trimMargins: trimMargins)) {
      throw ArgumentError(
        'Сетка должна быть от 1×1 до 8×8, макет — не больше 16 Мпикс. '
        'Обрезка полей требует измеренную ленту с непустым безопасным прямоугольником.',
      );
    }
  }

  MediaProfile get media => _media;
  set media(MediaProfile value) {
    _validateLayout(value, _rows, _columns, trimMargins: trimMargins);
    _media = value;
  }

  bool get trimMargins => _trimMargins;
  set trimMargins(bool value) {
    _validateLayout(_media, _rows, _columns, trimMargins: value);
    _trimMargins = value;
  }

  double get lengthMm => media.lengthMm;
  set lengthMm(num value) {
    if (value != media.lengthMm) {
      media = media.copyWith(lengthMm: value.toDouble());
    }
  }

  int get rows => _rows;
  set rows(int value) {
    _validateLayout(_media, value, _columns, trimMargins: trimMargins);
    _rows = value;
  }

  int get columns => _columns;
  set columns(int value) {
    _validateLayout(_media, _rows, value, trimMargins: trimMargins);
    _columns = value;
  }

  final List<LabelElement> elements;
  int get tileWidth =>
      trimMargins ? media.safeRect.width.toInt() : media.rasterRows;
  int get tileHeight =>
      trimMargins ? media.safeRect.height.toInt() : media.paperHeightDots;
  int get width => tileWidth * columns;
  int get canvasHeight => tileHeight * rows;
  int get tileCount => rows * columns;

  Rect tileRect(int index) {
    RangeError.checkValueInInterval(index, 0, tileCount - 1, 'index');
    return Rect.fromLTWH(
      (index % columns * tileWidth).toDouble(),
      (index ~/ columns * tileHeight).toDouble(),
      tileWidth.toDouble(),
      tileHeight.toDouble(),
    );
  }

  static const int printHeadDots = geometry.printHeadDots;

  Path get paperPath {
    final path = Path();
    if (trimMargins) {
      return path..addRect(
        Rect.fromLTWH(0, 0, width.toDouble(), canvasHeight.toDouble()),
      );
    }
    final tile = media.paperPath;
    for (var i = 0; i < tileCount; i++) {
      path.addPath(tile, tileRect(i).topLeft);
    }
    return path;
  }

  Path get printablePath {
    final path = Path();
    if (trimMargins) {
      return path..addRect(
        Rect.fromLTWH(0, 0, width.toDouble(), canvasHeight.toDouble()),
      );
    }
    final tile = media.printablePath;
    for (var i = 0; i < tileCount; i++) {
      path.addPath(tile, tileRect(i).topLeft);
    }
    return path;
  }

  Map<String, dynamic> toJson() => {
    'version': 4,
    'name': name,
    'media': media.toJson(),
    'rows': rows,
    'columns': columns,
    'trimMargins': trimMargins,
    'elements': elements.map((e) => e.toJson()).toList(),
  };
  factory LabelDocument.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 &&
        json['version'] != 2 &&
        json['version'] != 3 &&
        json['version'] != 4) {
      throw const FormatException('Неизвестная версия шаблона');
    }
    final MediaProfile media;
    try {
      media = json['version'] == 3 || json['version'] == 4
          ? MediaProfile.fromJson(
              Map<String, dynamic>.from(json['media'] as Map),
            )
          : MediaProfile(lengthMm: (json['lengthMm'] as num).toDouble());
    } catch (_) {
      throw const FormatException('Некорректный размер этикетки');
    }
    final rows = json['version'] == 1 ? 1 : json['rows'];
    final columns = json['version'] == 1 ? 1 : json['columns'];
    final trimMargins = json['version'] == 4 ? json['trimMargins'] : false;
    if (rows is! int ||
        columns is! int ||
        trimMargins is! bool ||
        !fitsLayout(media, rows, columns, trimMargins: trimMargins)) {
      throw const FormatException(
        'Некорректная или слишком большая сетка этикеток',
      );
    }
    final items = json['elements'] as List;
    if (items.length > 100) {
      throw const FormatException('Слишком много элементов');
    }
    final document = LabelDocument(
      name: json['name'] as String,
      media: media,
      rows: rows,
      columns: columns,
      trimMargins: trimMargins,
      elements: items
          .map(
            (e) => LabelElement.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList(),
    );
    for (final e in document.elements) {
      if (![
            e.x,
            e.y,
            e.width,
            e.height,
            e.rotation,
            e.fontSize,
            e.textScaleX,
            e.textScaleY,
          ].every((v) => v.isFinite) ||
          e.width <= 0 ||
          e.height <= 0 ||
          e.width > maxElementWidth ||
          e.height > maxElementHeight ||
          e.fontSize < 1 ||
          e.fontSize > 300 ||
          e.textScaleX < minTextScale ||
          e.textScaleY < minTextScale ||
          e.textScaleX > maxTextScale ||
          e.textScaleY > maxTextScale) {
        throw const FormatException('Некорректная геометрия элемента');
      }
    }
    return document;
  }
  void rotateHalfTurn() {
    for (final e in elements) {
      e.x = width - e.x - e.width;
      e.y = canvasHeight - e.y - e.height;
      e.rotation += math.pi;
    }
  }

  void dispose() {
    _contentCache[this]?.picture.dispose();
    _contentCache[this] = null;
    _colorContentCache[this]?.picture.dispose();
    _colorContentCache[this] = null;
    for (final e in elements) {
      e.dispose();
    }
  }
}

Future<ui.Image> rgbaImage(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: width,
    height: height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

void paintLabel(
  Canvas canvas,
  LabelDocument document, {
  bool colorImages = false,
}) {
  canvas.drawPath(
    document.paperPath,
    Paint()
      ..color = Colors.white
      ..isAntiAlias = false,
  );
  canvas.save();
  canvas.clipPath(document.printablePath, doAntiAlias: false);
  canvas.drawPicture(_contentPicture(document, colorImages: colorImages));
  canvas.restore();
}

class _RecordedContent {
  _RecordedContent(this.fingerprint, this.picture);
  final int fingerprint;
  final ui.Picture picture;
}

final _contentCache = Expando<_RecordedContent>();
final _colorContentCache = Expando<_RecordedContent>();

ui.Picture _contentPicture(LabelDocument document, {bool colorImages = false}) {
  final cache = colorImages ? _colorContentCache : _contentCache;
  final fingerprint = Object.hashAll(
    document.elements.map(
      (e) => Object.hashAll([
        e.kind,
        e.text,
        e.x,
        e.y,
        e.width,
        e.height,
        e.rotation,
        e.fontSize,
        e.bold,
        e.italic,
        e.underline,
        e.strikethrough,
        e.fontFamily,
        e.textResizeMode,
        e.textScaleX,
        e.textScaleY,
        e.image,
        e.colorImage,
        e.qr,
        e.inkOnly,
      ]),
    ),
  );
  final old = cache[document];
  if (old != null && old.fingerprint == fingerprint) return old.picture;
  final recorder = ui.PictureRecorder();
  _paintContent(Canvas(recorder), document, colorImages: colorImages);
  final picture = recorder.endRecording();
  old?.picture.dispose();
  cache[document] = _RecordedContent(fingerprint, picture);
  return picture;
}

void _paintContent(
  Canvas canvas,
  LabelDocument document, {
  bool colorImages = false,
}) {
  final black = Paint()
    ..color = Colors.black
    ..isAntiAlias = false;
  for (final e in document.elements) {
    canvas.save();
    canvas.translate(e.x + e.width / 2, e.y + e.height / 2);
    canvas.rotate(e.rotation);
    canvas.translate(-e.width / 2, -e.height / 2);
    final rect = Rect.fromLTWH(0, 0, e.width, e.height);
    if (e.kind == ElementKind.text) {
      final scaleX = e.textResizeMode == TextResizeMode.stretch
          ? e.textScaleX
          : 1.0;
      final scaleY = e.textResizeMode == TextResizeMode.stretch
          ? e.textScaleY
          : 1.0;
      final painter = TextPainter(
        text: TextSpan(
          text: e.text,
          style: TextStyle(
            color: Colors.black,
            fontSize: e.fontSize,
            height: 1.05,
            fontWeight: e.bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: e.italic ? FontStyle.italic : FontStyle.normal,
            fontFamily: e.fontFamily,
            fontFamilyFallback: internationalFontFallback,
            decoration: TextDecoration.combine([
              if (e.underline) TextDecoration.underline,
              if (e.strikethrough) TextDecoration.lineThrough,
            ]),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: e.width / scaleX);
      canvas.clipRect(rect);
      canvas.scale(scaleX, scaleY);
      painter.paint(canvas, Offset.zero);
      painter.dispose();
    } else if (e.kind == ElementKind.qr && e.qr != null) {
      final qr = e.qr!;
      final pitch = (math.min(e.width, e.height) / (qr.moduleCount + 8))
          .floor();
      if (pitch > 0) {
        final side = (qr.moduleCount + 8) * pitch;
        final left = ((e.width - side) / 2).floorToDouble() + 4 * pitch;
        final top = ((e.height - side) / 2).floorToDouble() + 4 * pitch;
        for (var y = 0; y < qr.moduleCount; y++) {
          for (var x = 0; x < qr.moduleCount; x++) {
            if (qr.isDark(y, x)) {
              canvas.drawRect(
                Rect.fromLTWH(
                  left + x * pitch,
                  top + y * pitch,
                  pitch.toDouble(),
                  pitch.toDouble(),
                ),
                black,
              );
            }
          }
        }
      }
    } else if (e.image != null) {
      final image = colorImages ? (e.colorImage ?? e.image!) : e.image!;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        rect,
        Paint()
          ..filterQuality = FilterQuality.none
          ..blendMode = e.inkOnly ? BlendMode.multiply : BlendMode.srcOver
          ..isAntiAlias = false,
      );
    }
    canvas.restore();
  }
}

Future<PrinterRaster> renderLabel(LabelDocument document) =>
    renderTile(document, 0);

/// Crops native logical dots into a physical raster; trim mode only translates.
Future<PrinterRaster> renderTile(LabelDocument document, int index) async {
  final tile = document.tileRect(index);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  if (document.trimMargins) {
    final safe = document.media.safeRect;
    canvas.translate(
      safe.left - document.media.feedOffsetDots - tile.left,
      safe.top - document.media.headOffsetDots - tile.top,
    );
    canvas.clipRect(tile, doAntiAlias: false);
  } else {
    canvas.translate(
      -tile.left - document.media.feedOffsetDots,
      -tile.top - document.media.headOffsetDots,
    );
    canvas.clipPath(
      document.media.printablePath.shift(tile.topLeft),
      doAntiAlias: false,
    );
  }
  canvas.drawPicture(_contentPicture(document));
  final picture = recorder.endRecording();
  ui.Image? image;
  final ByteData? bytes;
  try {
    image = await picture.toImage(
      document.media.rasterRows,
      LabelDocument.printHeadDots,
    );
    bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  } finally {
    image?.dispose();
    picture.dispose();
  }
  if (bytes == null) throw StateError('Не удалось растеризовать этикетку');
  final mono = monochromeRgba(
    bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    document.media.rasterRows,
    LabelDocument.printHeadDots,
    const RasterSettings(),
  );
  return rotateForPrinter(
    mono,
    document.media.rasterRows,
    LabelDocument.printHeadDots,
  );
}

/// Full, unrotated printable design for the live canvas.
Future<ui.Image> renderDesign(LabelDocument document) async {
  final recorder = ui.PictureRecorder();
  paintLabel(Canvas(recorder), document);
  final picture = recorder.endRecording();
  final image = await picture.toImage(document.width, document.canvasHeight);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (bytes == null) throw StateError('Не удалось растеризовать макет');
  return rgbaImage(
    monochromeRgba(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      document.width,
      document.canvasHeight,
      const RasterSettings(),
    ),
    document.width,
    document.canvasHeight,
  );
}

List<String> printWarnings(LabelDocument document) {
  final warnings = <String>[];
  if (!document.media.isCalibrated) {
    warnings.add(
      'Размер и совмещение ленты не измерены: выполните физическую калибровку.',
    );
  }
  if (document.trimMargins) {
    warnings.add(
      'Перед стыковкой обрежьте ножницами бумагу за безопасным прямоугольником: '
      'программа не убирает физические непечатаемые поля.',
    );
    if (document.tileCount > 1 &&
        document.elements.any((element) => element.kind == ElementKind.qr)) {
      warnings.add(
        'Совмещение наклеек и читаемость QR через физические стыки не проверены: '
        'нужна пробная печать и сканирование после обрезки.',
      );
    }
  }
  for (final e in document.elements) {
    if (e.width < 1 || e.height < 1) {
      warnings.add(
        'Размер элемента меньше одной точки печати: тонкая сторона может исчезнуть.',
      );
    }
    if (e.kind == ElementKind.qr) {
      final qr = e.qr;
      if (qr == null ||
          math.min(e.width, e.height) / (qr.moduleCount + 8) < 2) {
        warnings.add(
          'QR слишком мелкий: нужно минимум 2 точки на модуль и свободная рамка.',
        );
      }
    }
    final c = math.cos(e.rotation).abs(), s = math.sin(e.rotation).abs();
    final halfW = (e.width * c + e.height * s) / 2;
    final halfH = (e.width * s + e.height * c) / 2;
    final cx = e.x + e.width / 2, cy = e.y + e.height / 2;
    final bounds = Rect.fromLTRB(
      cx - halfW,
      cy - halfH,
      cx + halfW,
      cy + halfH,
    );
    final outside = Path.combine(
      PathOperation.difference,
      Path()..addRect(bounds),
      document.printablePath,
    );
    if (!outside.getBounds().isEmpty) {
      warnings.add(
        'Часть элемента будет обрезана: край бумаги, скругления или непечатаемое поле головки.',
      );
    }
  }
  return warnings.toSet().toList();
}
