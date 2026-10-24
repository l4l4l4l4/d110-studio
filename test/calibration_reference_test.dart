import 'dart:ui' as ui;

import 'package:d110_studio/calibration_photo_analysis.dart';
import 'package:d110_studio/image_decode.dart';
import 'package:d110_studio/media_calibration.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Synthetic paper, not an empirical measurement of any physical label.
Future<Uint8List> renderReferencePhotograph() async {
  final font = FontLoader('NotoSans')
    ..addFont(rootBundle.load('assets/fonts/NotoSans/NotoSans-Regular.ttf'));
  await font.load();
  final reference = await renderMediaCalibrationPattern(
    MediaProfile(lengthMm: 10),
  );
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xff202020), BlendMode.src);
  final paper = RRect.fromRectAndRadius(
    const Rect.fromLTWH(140, 120, 960, 384),
    const Radius.circular(48),
  );
  canvas.drawRRect(paper, Paint()..color = Colors.white);
  canvas.clipRRect(paper);
  final ink = Paint()
    ..color = Colors.black
    ..isAntiAlias = false;
  for (var feed = 0; feed < reference.height; feed++) {
    for (var head = 0; head < 96; head++) {
      final nativeHead = 95 - head;
      if ((reference.packed[feed * 12 + nativeHead ~/ 8] &
              (0x80 >> (nativeHead % 8))) !=
          0) {
        canvas.drawRect(
          Rect.fromLTWH(140 + (feed + 4) * 4.0, 120 + head * 4.0, 4, 4),
          ink,
        );
      }
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(1280, 720);
  try {
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual packed short reference and bundled font retain measurable fiducials and ruler phase',
    () async {
      final encoded = await renderReferencePhotograph();
      final decoded = await decodeLabelImage(
        encoded,
        maxDimension: 1800,
        maxPixels: 3240000,
      );
      try {
        final data = (await decoded.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final result = analyzeCalibrationPhoto(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          decoded.image.width,
          decoded.image.height,
          referenceRows: 80,
        );
        expect(result.lengthMm, closeTo(30, .15));
        expect(result.widthMm, closeTo(12, .15));
        expect(result.radiusMm, closeTo(1.5, .2));
        expect(result.feedOffsetDots, closeTo(4, 1));
        expect(result.headOffsetDots, closeTo(0, 1));
        expect(result.edgeErrorDots, lessThan(1));
      } finally {
        decoded.image.dispose();
      }
    },
  );
}
