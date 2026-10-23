import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:d110_studio/label.dart';
import 'package:d110_studio/media_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'fractional paper dimensions roundtrip without duplicate legacy length',
    () {
      final media = MediaProfile(
        lengthMm: 30.125,
        widthMm: 14.25,
        radiusMm: 1.5,
        feedOffsetDots: -2,
        headOffsetDots: 7,
        name: 'Measured roll',
        measuredAt: DateTime.utc(2026, 10, 23),
      );
      final document = LabelDocument(media: media, rows: 2, columns: 2);
      addTearDown(document.dispose);
      expect(document.tileWidth, 241);
      expect(document.tileHeight, 114);
      expect(document.tileRect(3), const ui.Rect.fromLTWH(241, 114, 241, 114));
      expect(document.toJson().containsKey('lengthMm'), isFalse);
      final restored = LabelDocument.fromJson(document.toJson());
      addTearDown(restored.dispose);
      expect(restored.media.toJson(), media.toJson());
      restored.lengthMm = restored.lengthMm;
      expect(restored.media.measuredAt, media.measuredAt);
      restored.lengthMm = 30.25;
      expect(restored.media.measuredAt, isNull);
      expect(restored.media.widthMm, 14.25);
    },
  );

  test(
    'all physical adjustments invalidate measurement but renaming does not',
    () {
      final media = MediaProfile(measuredAt: DateTime.utc(2026));
      expect(media.copyWith(name: 'Renamed').measuredAt, media.measuredAt);
      for (final changed in [
        media.copyWith(lengthMm: 31),
        media.copyWith(widthMm: 13),
        media.copyWith(radiusMm: 1),
        media.copyWith(feedOffsetDots: 1),
        media.copyWith(headOffsetDots: 1),
        media.copyWith(clearMeasurement: true),
      ]) {
        expect(changed.isCalibrated, isFalse);
      }
    },
  );

  test(
    'live color and monochrome previews share per-tile head and corner masks',
    () async {
      final mono = await rgbaImage(Uint8List.fromList([0, 0, 0, 255]), 1, 1);
      final color = await rgbaImage(Uint8List.fromList([255, 0, 0, 255]), 1, 1);
      final document = LabelDocument(
        media: MediaProfile(lengthMm: 10, radiusMm: 2, headOffsetDots: 8),
        columns: 2,
        elements: [
          LabelElement(
              kind: ElementKind.image,
              x: 0,
              y: 0,
              width: 160,
              height: 96,
            )
            ..image = mono
            ..colorImage = color,
        ],
      );
      addTearDown(document.dispose);
      for (final colorImages in [false, true]) {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
        paintLabel(canvas, document, colorImages: colorImages);
        final picture = recorder.endRecording();
        final image = await picture.toImage(160, 96);
        picture.dispose();
        final pixels = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        image.dispose();
        for (final tileX in [0, 80]) {
          int channel(int x, int y, int c) =>
              pixels!.getUint8((y * 160 + tileX + x) * 4 + c);
          expect(
            channel(40, 2, 1),
            255,
            reason: 'unprintable leading head margin',
          );
          expect(channel(0, 8, 1), 255, reason: 'rounded corner on each tile');
          expect(channel(40, 48, 0), colorImages ? 255 : 0);
          expect(channel(40, 48, 1), 0);
        }
      }
    },
  );

  test(
    'invalid measurements and head entirely off rounded paper are rejected',
    () {
      for (final value in [double.nan, double.infinity, 9.9, 150.1]) {
        expect(() => MediaProfile(lengthMm: value), throwsArgumentError);
      }
      expect(() => MediaProfile(widthMm: 0), throwsArgumentError);
      expect(() => MediaProfile(radiusMm: 6.1), throwsArgumentError);
      expect(() => MediaProfile(headOffsetDots: 96), throwsArgumentError);
      expect(() => MediaProfile(feedOffsetDots: 240), throwsArgumentError);
      expect(
        () => MediaProfile.fromJson({'lengthMm': 30}),
        throwsFormatException,
      );
    },
  );

  test(
    'rounded masks clip every tile without deleting recoverable artwork',
    () async {
      final black = await rgbaImage(Uint8List.fromList([0, 0, 0, 255]), 1, 1);
      final element = LabelElement(
        kind: ElementKind.image,
        x: 0,
        y: 0,
        width: 160,
        height: 192,
      )..image = black;
      final document = LabelDocument(
        media: MediaProfile(lengthMm: 10, radiusMm: 2),
        rows: 2,
        columns: 2,
        elements: [element],
      );
      addTearDown(document.dispose);
      final source = element.toJson();
      for (var tile = 0; tile < 4; tile++) {
        final raster = await renderTile(document, tile);
        expect(raster.width, 96);
        expect(raster.height, 80);
        expect(
          raster.rgba[(0 * 96 + 95) * 4],
          255,
          reason: 'tile $tile rounded corner',
        );
        expect(
          raster.rgba[(40 * 96 + 47) * 4],
          0,
          reason: 'tile $tile interior',
        );
      }
      final preview = await renderDesign(document);
      final bytes = await preview.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      preview.dispose();
      for (final point in [
        const ui.Offset(0, 0),
        const ui.Offset(80, 0),
        const ui.Offset(0, 96),
        const ui.Offset(80, 96),
      ]) {
        final i = (point.dy.toInt() * 160 + point.dx.toInt()) * 4;
        expect(bytes!.getUint8(i), 255);
      }
      expect(printWarnings(document).join(' '), contains('скругления'));
      document.media = document.media.copyWith(radiusMm: 0);
      final recovered = await renderTile(document, 3);
      expect(recovered.rgba[95 * 4], 0);
      expect(element.toJson(), source);
    },
  );

  test(
    'head and feed offsets translate exact pixels without rescaling or neighbor leaks',
    () async {
      final black = await rgbaImage(Uint8List.fromList([0, 0, 0, 255]), 1, 1);
      final document = LabelDocument(
        media: MediaProfile(
          lengthMm: 10.125,
          widthMm: 15,
          feedOffsetDots: -2,
          headOffsetDots: 12,
        ),
        columns: 2,
        elements: [
          LabelElement(
            kind: ElementKind.image,
            x: 3,
            y: 15,
            width: 1,
            height: 1,
          )..image = black,
        ],
      );
      addTearDown(document.dispose);
      final raster = await renderTile(document, 0);
      expect(raster.width, 96);
      expect(raster.height, 81);
      final index = (5 * 96 + (95 - 3)) * 4;
      expect(raster.rgba[index], 0);
      expect(raster.rgba.where((b) => b == 0).length, 3);
      final second = await renderTile(document, 1);
      expect(second.rgba.where((b) => b == 0), isEmpty);
      document.media = document.media.copyWith(feedOffsetDots: -80);
      final shifted = await renderTile(document, 1);
      expect(
        shifted.rgba.where((b) => b == 0),
        isEmpty,
        reason: 'previous tile must not appear in the blank leading raster',
      );
    },
  );

  test(
    'narrow paper leaves unused head columns white and fractional edge is not stretched',
    () async {
      final black = await rgbaImage(Uint8List.fromList([0, 0, 0, 255]), 1, 1);
      final document = LabelDocument(
        media: MediaProfile(lengthMm: 10.01, widthMm: 8),
        elements: [
          LabelElement(
            kind: ElementKind.image,
            x: 0,
            y: 0,
            width: 81,
            height: 96,
          )..image = black,
        ],
      );
      addTearDown(document.dispose);
      final raster = await renderLabel(document);
      expect(raster.width, 96);
      expect(raster.height, 81);
      expect(raster.rgba[0], 255, reason: 'outside 64-dot physical width');
      expect(raster.rgba[95 * 4], 0);
      expect(raster.packed.length, 81 * 12);
    },
  );
  test(
    'large paper grids reject oversized canvas before raster allocation',
    () {
      expect(
        () => LabelDocument(
          media: MediaProfile(lengthMm: 150, widthMm: 150),
          rows: 8,
          columns: 8,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'large paper grids reject mutations without damaging the current layout',
    () {
      final document = LabelDocument(rows: 8, columns: 8);
      addTearDown(document.dispose);
      final original = document.media;
      expect(
        () => document.media = MediaProfile(lengthMm: 150, widthMm: 150),
        throwsArgumentError,
      );
      expect(document.media, same(original));
      final wide = LabelDocument(
        media: MediaProfile(lengthMm: 150, widthMm: 150),
        rows: 2,
        columns: 2,
      );
      addTearDown(wide.dispose);
      expect(() => wide.rows = 8, throwsArgumentError);
      expect(wide.rows, 2);
      expect(wide.columns, 2);
    },
  );
}
