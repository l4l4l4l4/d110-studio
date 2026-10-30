import 'dart:convert';
import 'dart:ui' as ui;
import 'package:d110_studio/app_state_store.dart';
import 'package:d110_studio/last_printed.dart';
import 'package:d110_studio/workspace.dart';
import 'package:flutter/services.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:d110_studio/raster.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:d110_studio/label.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'trim geometry survives last printed and workspace snapshot storage',
    () async {
      const channel = MethodChannel('test/trim-label-state');
      final files = <String, String>{};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final args = call.arguments as Map;
            if (call.method == 'readState') return files[args['slot']];
            files[args['slot'] as String] = args['json'] as String;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final document = LabelDocument(
        media: MediaProfile(
          lengthMm: 10,
          widthMm: 14,
          radiusMm: 2,
          feedOffsetDots: 9,
          headOffsetDots: 8,
          measuredAt: DateTime.utc(2026, 10, 30),
        ),
        rows: 2,
        columns: 2,
        trimMargins: true,
      );
      final workspace = DesignWorkspace(document);
      addTearDown(workspace.dispose);
      final expected = document.toJson();
      final history = LastPrintedHistory(AppStateStore(channel: channel));
      final job = LastPrintedJob.capture(document, history);
      document.trimMargins = false;
      expect(await job.confirmed(), isNull);
      final restoredPrint = await history.restore();
      addTearDown(restoredPrint!.dispose);
      expect(restoredPrint.toJson(), expected);
      document.trimMargins = true;
      final store = AppStateStore(channel: channel);
      await store.write(AppStateSlot.workspace, jsonEncode(workspace.toJson()));
      final restoredWorkspace = await DesignWorkspace.restore(
        await store.read(AppStateSlot.workspace),
        printedSnapshot: await history.readSnapshot(),
      );
      addTearDown(restoredWorkspace.dispose);
      expect(restoredWorkspace.tabs, hasLength(1));
      expect(restoredWorkspace.active.document.toJson(), expected);
      expect(restoredWorkspace.active.document.trimMargins, isTrue);
    },
  );

  test('trim margins requires measured positive safe cells and persists', () {
    final measured = MediaProfile(
      lengthMm: 10,
      widthMm: 14,
      radiusMm: 2,
      feedOffsetDots: 9,
      headOffsetDots: 8,
      measuredAt: DateTime.utc(2026, 10, 30),
    );
    final document = LabelDocument(
      media: measured,
      rows: 2,
      columns: 2,
      trimMargins: true,
    );
    addTearDown(document.dispose);
    expect(document.tileWidth, measured.safeRect.width.toInt());
    expect(document.tileHeight, measured.safeRect.height.toInt());
    expect(document.width, document.tileWidth * 2);
    expect(document.canvasHeight, document.tileHeight * 2);
    final saved = document.toJson();
    expect(saved['version'], 4);
    expect(saved['trimMargins'], isTrue);
    final restored = LabelDocument.fromJson(saved);
    addTearDown(restored.dispose);
    expect(restored.toJson(), saved);
    final legacy = Map<String, dynamic>.from(saved)..['version'] = 3;
    final normal = LabelDocument.fromJson(legacy);
    addTearDown(normal.dispose);
    expect(normal.trimMargins, isFalse);
    expect(normal.tileWidth, measured.rasterRows);
    expect(normal.tileHeight, measured.paperHeightDots);
    expect(() => LabelDocument(trimMargins: true), throwsArgumentError);
    expect(
      () => document.media = measured.copyWith(clearMeasurement: true),
      throwsArgumentError,
    );
    expect(document.media, same(measured));
    final unmeasured = Map<String, dynamic>.from(saved)
      ..['media'] = measured.copyWith(clearMeasurement: true).toJson();
    expect(() => LabelDocument.fromJson(unmeasured), throwsFormatException);
    final emptySafe = MediaProfile(
      lengthMm: 10,
      widthMm: 1.01,
      headOffsetDots: 8,
      measuredAt: measured.measuredAt,
    );
    expect(emptySafe.safeRect.isEmpty, isTrue);
    expect(
      () => LabelDocument(media: emptySafe, trimMargins: true),
      throwsArgumentError,
    );
    final invalidFlag = Map<String, dynamic>.from(saved)
      ..['trimMargins'] = 'true';
    expect(() => LabelDocument.fromJson(invalidFlag), throwsFormatException);
    final normalSaved = normal.toJson();
    final normalRestored = LabelDocument.fromJson(normalSaved);
    addTearDown(normalRestored.dispose);
    expect(normalRestored.toJson(), normalSaved);
  });

  test('trim layouts retain the 16 megapixel logical canvas budget', () {
    final measured = MediaProfile(
      lengthMm: 150,
      widthMm: 150,
      measuredAt: DateTime.utc(2026, 10, 30),
    );
    expect(LabelDocument.fitsLayout(measured, 8, 8), isFalse);
    expect(LabelDocument.fitsLayout(measured, 8, 8, trimMargins: true), isTrue);
    final document = LabelDocument(
      media: measured,
      rows: 8,
      columns: 8,
      trimMargins: true,
    );
    addTearDown(document.dispose);
    expect(document.width * document.canvasHeight, lessThanOrEqualTo(16000000));
    expect(() => document.trimMargins = false, throwsArgumentError);
    expect(document.trimMargins, isTrue);
  });

  for (final profile in [
    MediaProfile(
      lengthMm: 10,
      widthMm: 14,
      radiusMm: 2,
      feedOffsetDots: 9,
      headOffsetDots: 8,
      measuredAt: DateTime.utc(2026, 10, 30),
    ),
    MediaProfile(
      lengthMm: 10.125,
      widthMm: 11.125,
      radiusMm: 1.5,
      feedOffsetDots: -7,
      headOffsetDots: -4,
      measuredAt: DateTime.utc(2026, 10, 30),
    ),
  ]) {
    test(
      'trim crops reconstruct native 2×2 pixels for ${profile.toJson()}',
      () async {
        final document = LabelDocument(
          media: profile,
          rows: 2,
          columns: 2,
          trimMargins: true,
        );
        addTearDown(document.dispose);
        final source = Uint8List(document.width * document.canvasHeight * 4);
        for (var y = 0; y < document.canvasHeight; y++) {
          for (var x = 0; x < document.width; x++) {
            final offset = (y * document.width + x) * 4;
            // Asymmetric marks include every cell border and both sides of seams.
            final black =
                x % document.tileWidth == 0 ||
                x % document.tileWidth == document.tileWidth - 1 ||
                y % document.tileHeight == 0 ||
                y % document.tileHeight == document.tileHeight - 1 ||
                (x * 13 + y * 7) % 19 < 5;
            source[offset] = source[offset + 1] = source[offset + 2] = black
                ? 0
                : 255;
            source[offset + 3] = 255;
          }
        }
        document.elements.add(
          LabelElement(
              kind: ElementKind.image,
              x: 0,
              y: 0,
              width: document.width.toDouble(),
              height: document.canvasHeight.toDouble(),
            )
            ..image = await rgbaImage(
              source,
              document.width,
              document.canvasHeight,
            ),
        );
        final reconstructed = Uint8List(source.length);
        final safe = profile.safeRect;
        for (var index = 0; index < 4; index++) {
          final raster = await renderTile(document, index);
          expect(raster.width, 96);
          expect(raster.height, profile.rasterRows);
          for (var feed = 0; feed < profile.rasterRows; feed++) {
            for (var head = 0; head < 96; head++) {
              final paperX = feed + profile.feedOffsetDots;
              final paperY = head + profile.headOffsetDots;
              final pixel = (feed * 96 + 95 - head) * 4;
              if (!safe.contains(ui.Offset(paperX + .5, paperY + .5))) {
                expect(
                  raster.rgba[pixel],
                  255,
                  reason: 'untrimmed physical margin',
                );
                continue;
              }
              final x =
                  index % 2 * document.tileWidth + paperX - safe.left.toInt();
              final y =
                  index ~/ 2 * document.tileHeight + paperY - safe.top.toInt();
              final target = (y * document.width + x) * 4;
              reconstructed.setRange(target, target + 4, raster.rgba, pixel);
            }
          }
        }
        expect(reconstructed, orderedEquals(source));
        final preview = await renderDesign(document);
        try {
          expect(preview.width, document.width);
          expect(preview.height, document.canvasHeight);
          final bytes = await preview.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(
            bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
            orderedEquals(source),
          );
        } finally {
          preview.dispose();
        }
      },
    );
  }

  test(
    'trim QR keeps native border modules across rounded offset seams',
    () async {
      final media = MediaProfile(
        lengthMm: 10,
        widthMm: 12,
        radiusMm: 2,
        feedOffsetDots: 8,
        headOffsetDots: 7,
        measuredAt: DateTime.utc(2026, 10, 30),
      );
      final document = LabelDocument(
        media: media,
        rows: 2,
        columns: 2,
        trimMargins: true,
      );
      addTearDown(document.dispose);
      final qr = LabelElement(
        kind: ElementKind.qr,
        text: 'TRIM',
        x: (document.tileWidth - 29).toDouble(),
        y: (document.tileHeight - 29).toDouble(),
        width: 58,
        height: 58,
      );
      await qr.prepare();
      document.elements.add(qr);
      expect(qr.qr!.moduleCount, 21);
      var dark = 0;
      for (var index = 0; index < 4; index++) {
        final raster = await renderTile(document, index);
        final tile = document.tileRect(index);
        for (var y = 0; y < document.tileHeight; y++) {
          for (var x = 0; x < document.tileWidth; x++) {
            final moduleX = ((tile.left + x - qr.x - 8) / 2).floor();
            final moduleY = ((tile.top + y - qr.y - 8) / 2).floor();
            final expected =
                moduleX >= 0 &&
                moduleX < 21 &&
                moduleY >= 0 &&
                moduleY < 21 &&
                qr.qr!.isDark(moduleY, moduleX);
            final feed = x + media.safeRect.left.toInt() - media.feedOffsetDots;
            final head = y + media.safeRect.top.toInt() - media.headOffsetDots;
            expect(
              raster.rgba[(feed * 96 + 95 - head) * 4],
              expected ? 0 : 255,
            );
            if (expected) dark++;
          }
        }
      }
      var darkModules = 0;
      for (var y = 0; y < 21; y++) {
        for (var x = 0; x < 21; x++) {
          if (qr.qr!.isDark(y, x)) darkModules++;
        }
      }
      expect(
        dark,
        darkModules * 4,
        reason: 'each module stays exactly 2×2 dots',
      );
      expect(printWarnings(document).join(' '), contains('ножниц'));
      expect(printWarnings(document).join(' '), contains('не проверены'));
      expect(
        printWarnings(
          document,
        ).where((warning) => warning.contains('обрезана')),
        isEmpty,
      );
    },
  );

  test('legacy paper stays visibly uncalibrated after template migration', () {
    final legacy =
        LabelDocument(
            elements: [
              LabelElement(kind: ElementKind.text, text: 'Keep artwork'),
            ],
          ).toJson()
          ..['version'] = 2
          ..['lengthMm'] = 30
          ..remove('media');
    final restored = LabelDocument.fromJson(legacy);
    addTearDown(restored.dispose);
    final saved = restored.toJson();
    expect(saved['version'], 4);
    expect((saved['media'] as Map)['measuredAt'], isNull);
    expect(restored.elements.single.text, 'Keep artwork');
  });

  test(
    'maximum-width image templates survive reducing the stack grid',
    () async {
      final image = await rgbaImage(Uint8List.fromList([0, 0, 0, 255]), 1, 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final document = LabelDocument(
        lengthMm: 150,
        columns: 8,
        rows: 8,
        elements: [
          LabelElement(
            kind: ElementKind.image,
            imageBytes: png!.buffer.asUint8List(
              png.offsetInBytes,
              png.lengthInBytes,
            ),
            width: 9600,
            height: 768,
          ),
        ],
      );
      addTearDown(document.dispose);
      final restored = LabelDocument.fromJson(document.toJson());
      addTearDown(restored.dispose);
      expect(restored.elements.single.width, 9600);
      restored
        ..columns = 1
        ..rows = 1;
      final reduced = LabelDocument.fromJson(restored.toJson());
      addTearDown(reduced.dispose);
      expect(reduced.elements.single.width, 9600);
      expect(reduced.elements.single.height, 768);
      reduced.elements.single.width = 9601;
      expect(
        () => LabelDocument.fromJson(reduced.toJson()),
        throwsFormatException,
      );
    },
  );

  test('v1 templates migrate losslessly and grid documents roundtrip', () {
    final original = LabelDocument(
      elements: [
        LabelElement(
          kind: ElementKind.text,
          text: 'Across seams',
          x: 230,
          y: 90,
        ),
      ],
    );
    final legacy = original.toJson()
      ..['version'] = 1
      ..['lengthMm'] = original.lengthMm
      ..remove('media')
      ..remove('rows')
      ..remove('columns');
    final migrated = LabelDocument.fromJson(legacy);
    expect(migrated.rows, 1);
    expect(migrated.columns, 1);
    expect(
      migrated.elements.single.toJson(),
      original.elements.single.toJson(),
    );
    migrated.rows = 3;
    migrated.columns = 2;
    final restored = LabelDocument.fromJson(migrated.toJson());
    expect(restored.canvasHeight, 288);
    expect(restored.tileWidth, 240);
    expect(restored.width, 480);
    expect(restored.toJson(), migrated.toJson());
    expect(LabelDocument.printHeadDots, 96);
    final invalid = restored.toJson()..['columns'] = 9;
    expect(() => LabelDocument.fromJson(invalid), throwsFormatException);
  });

  test(
    'tiles crop exact seam pixels without squeezing the full composition',
    () async {
      final image = await rgbaImage(
        monochromeRgba(
          Uint8List.fromList([0, 0, 0, 255]),
          1,
          1,
          const RasterSettings(),
        ),
        1,
        1,
      );
      final marker = LabelElement(
        kind: ElementKind.image,
        x: 79,
        y: 95,
        width: 2,
        height: 2,
      )..image = image;
      final document = LabelDocument(
        lengthMm: 10,
        rows: 2,
        columns: 2,
        elements: [marker],
      );
      try {
        for (var index = 0; index < 4; index++) {
          final raster = await renderTile(document, index);
          expect(raster.width, 96);
          expect(raster.height, 80);
          final x = index.isEven ? 79 : 0;
          final y = index < 2 ? 95 : 0;
          final blackPixel = (x * 96 + (95 - y)) * 4;
          expect(raster.rgba[blackPixel], 0, reason: 'tile $index corner');
          expect(
            raster.rgba.where((value) => value == 0).length,
            3,
            reason: 'exactly one black RGB pixel in tile $index',
          );
        }
      } finally {
        document.dispose();
      }
    },
  );

  test(
    'live image settings rebuild printable pixels and retain color source',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final source = await picture.toImage(1, 1);
      picture.dispose();
      final png = await source.toByteData(format: ui.ImageByteFormat.png);
      source.dispose();
      final element = LabelElement(
        kind: ElementKind.image,
        imageBytes: png!.buffer.asUint8List(
          png.offsetInBytes,
          png.lengthInBytes,
        ),
        settings: const RasterSettings(
          mode: RasterMode.threshold,
          threshold: 128,
        ),
      );
      try {
        await element.prepare();
        final original = element.colorImage;
        final black = await element.image!.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(black!.getUint8(0), 0);
        element.settings = element.settings.copyWith(invert: true);
        await element.prepare();
        final white = await element.image!.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(white!.getUint8(0), 255);
        expect(element.colorImage, same(original));
        final color = await element.colorImage!.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        expect(
          color!.buffer.asUint8List(color.offsetInBytes, color.lengthInBytes),
          [255, 0, 0, 255],
        );
      } finally {
        element.dispose();
      }
    },
  );

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
