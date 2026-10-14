import 'dart:ui' as ui;
import 'package:d110_studio/raster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:d110_studio/label.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('translucent PNG is composited once before thresholding', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const ui.Color(0x80c8c8c8), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final source = await picture.toImage(1, 1);
    picture.dispose();
    final png = await source.toByteData(format: ui.ImageByteFormat.png);
    source.dispose();
    final element = LabelElement(
      kind: ElementKind.image,
      imageBytes: png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      settings: const RasterSettings(threshold: 192),
    );
    try {
      await element.prepare();
      final pixel = await element.image!.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      expect(
        pixel!.buffer.asUint8List(pixel.offsetInBytes, pixel.lengthInBytes),
        [255, 255, 255, 255],
      );
    } finally {
      element.dispose();
    }
  });
  test('imported PNG retains its black and white pixels', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    canvas.drawRect(
      const ui.Rect.fromLTWH(1, 1, 1, 1),
      ui.Paint()..color = const ui.Color(0xff000000),
    );
    final picture = recorder.endRecording();
    final source = await picture.toImage(3, 3);
    picture.dispose();
    final png = await source.toByteData(format: ui.ImageByteFormat.png);
    source.dispose();
    final element = LabelElement(
      kind: ElementKind.image,
      imageBytes: png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      settings: const RasterSettings(
        mode: RasterMode.threshold,
        threshold: 128,
      ),
    );
    try {
      await element.prepare();
      final pixels = await element.image!.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final expected = [
        for (var i = 0; i < 9; i++) ...[
          i == 4 ? 0 : 255,
          i == 4 ? 0 : 255,
          i == 4 ? 0 : 255,
          255,
        ],
      ];
      expect(
        pixels!.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes),
        expected,
      );
    } finally {
      element.dispose();
    }
  });
  test(
    'transparent QR does not erase an underlying object in its margin',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final source = await picture.toImage(1, 1);
      picture.dispose();
      final png = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      final marker = LabelElement(
        kind: ElementKind.image,
        x: 4,
        y: 4,
        width: 4,
        height: 4,
        imageBytes: png!.buffer.asUint8List(
          png.offsetInBytes,
          png.lengthInBytes,
        ),
      );
      final qr = LabelElement(
        kind: ElementKind.qr,
        text: 'D110',
        x: 0,
        y: 0,
        width: 87,
        height: 87,
      );
      final document = LabelDocument(lengthMm: 20, elements: [marker, qr]);
      try {
        await marker.prepare();
        await qr.prepare();
        final raster = await renderLabel(document);
        // Clockwise conversion maps label (6,6) to printhead (89,6).
        final pixel = (6 * raster.width + 89) * 4;
        expect(raster.rgba.sublist(pixel, pixel + 4), [0, 0, 0, 255]);
      } finally {
        document.dispose();
      }
    },
  );
  test(
    'text stretch changes glyph aspect while box mode preserves it',
    () async {
      final element = LabelElement(
        kind: ElementKind.text,
        text: 'AB',
        x: 8,
        y: 8,
        width: 100,
        height: 40,
        fontSize: 20,
      );
      final document = LabelDocument(lengthMm: 30, elements: [element]);
      try {
        final original = inkBounds(await renderLabel(document));
        element.width = 200;
        element.height = 60;
        element.textResizeMode = TextResizeMode.stretch;
        element.textScaleX = 2;
        element.textScaleY = 1.5;
        final stretched = inkBounds(await renderLabel(document));
        // Label X maps to print Y; label Y maps to print X.
        expect(stretched.height, closeTo(original.height * 2, 2));
        expect(stretched.width, closeTo(original.width * 1.5, 2));
        element.textResizeMode = TextResizeMode.box;
        final box = inkBounds(await renderLabel(document));
        expect(box, original);
      } finally {
        document.dispose();
      }
    },
  );
  test('invalid edited QR cannot keep printing the old payload', () async {
    final element = LabelElement(kind: ElementKind.qr, text: 'old payload');
    await element.prepare();
    element.text = List.filled(5000, 'x').join();
    await expectLater(element.prepare(), throwsA(anything));
    expect(element.qr, isNull);
  });
}

ui.Rect inkBounds(PrinterRaster raster) {
  var left = raster.width, top = raster.height, right = -1, bottom = -1;
  for (var y = 0; y < raster.height; y++) {
    for (var x = 0; x < raster.width; x++) {
      if (raster.rgba[(y * raster.width + x) * 4] != 0) continue;
      if (x < left) left = x;
      if (x > right) right = x;
      if (y < top) top = y;
      if (y > bottom) bottom = y;
    }
  }
  return ui.Rect.fromLTRB(
    left.toDouble(),
    top.toDouble(),
    (right + 1).toDouble(),
    (bottom + 1).toDouble(),
  );
}
