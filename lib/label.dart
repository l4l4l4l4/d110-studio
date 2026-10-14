import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:qr/qr.dart';
import 'raster.dart';
import 'fonts.dart';
import 'image_decode.dart';

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
  RasterSettings settings;
  ui.Image? image;
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
        final decoded = await decodeLabelImage(imageBytes!);
        try {
          final rgba = await decoded.image.toByteData(
            format: ui.ImageByteFormat.rawStraightRgba,
          );
          if (rgba == null) {
            throw StateError('Не удалось прочитать изображение');
          }
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
    _sourceRgba = null;
  }
}

class LabelDocument {
  LabelDocument({
    this.name = 'Моя этикетка',
    this.lengthMm = 30,
    List<LabelElement>? elements,
  }) : elements = elements ?? [];
  String name;
  int lengthMm;
  final List<LabelElement> elements;
  int get width => lengthMm * 8;
  static const int height = 96;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'name': name,
    'lengthMm': lengthMm,
    'elements': elements.map((e) => e.toJson()).toList(),
  };
  factory LabelDocument.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Неизвестная версия шаблона');
    }
    final length = json['lengthMm'] as int;
    if (length < 10 || length > 150) {
      throw const FormatException('Некорректный размер этикетки');
    }
    final items = json['elements'] as List;
    if (items.length > 100) {
      throw const FormatException('Слишком много элементов');
    }
    final document = LabelDocument(
      name: json['name'] as String,
      lengthMm: length,
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
          e.width > 2400 ||
          e.height > 2400 ||
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
      e.y = height - e.y - e.height;
      e.rotation += math.pi;
    }
  }

  void dispose() {
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

void paintLabel(Canvas canvas, LabelDocument document) {
  canvas.drawRect(
    Rect.fromLTWH(
      0,
      0,
      document.width.toDouble(),
      LabelDocument.height.toDouble(),
    ),
    Paint()
      ..color = Colors.white
      ..isAntiAlias = false,
  );
  canvas.save();
  canvas.clipRect(
    Rect.fromLTWH(
      0,
      0,
      document.width.toDouble(),
      LabelDocument.height.toDouble(),
    ),
  );
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
      final image = e.image!;
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        rect,
        Paint()
          ..filterQuality = FilterQuality.none
          ..isAntiAlias = false,
      );
    }
    canvas.restore();
  }
  canvas.restore();
}

Future<PrinterRaster> renderLabel(LabelDocument document) async {
  final recorder = ui.PictureRecorder();
  paintLabel(Canvas(recorder), document);
  final picture = recorder.endRecording();
  final image = await picture.toImage(document.width, LabelDocument.height);
  picture.dispose();
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (bytes == null) throw StateError('Не удалось растеризовать этикетку');
  final mono = monochromeRgba(
    bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    document.width,
    LabelDocument.height,
    const RasterSettings(),
  );
  return rotateForPrinter(mono, document.width, LabelDocument.height);
}

List<String> printWarnings(LabelDocument document) {
  final warnings = <String>[];
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
    if (cx - halfW < -0.01 ||
        cy - halfH < -0.01 ||
        cx + halfW > document.width + .01 ||
        cy + halfH > LabelDocument.height + .01) {
      warnings.add('Часть элемента выходит за край и будет обрезана.');
    }
  }
  return warnings.toSet().toList();
}
