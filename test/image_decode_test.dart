import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d110_studio/image_decode.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff000000), ui.BlendMode.src);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, height / 2, width.toDouble(), height / 2),
    ui.Paint()..color = const ui.Color(0xffffffff),
  );
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in [(1025, 511, 512, 255), (511, 1025, 255, 512)]) {
    test(
      'bounds ${size.$1}x${size.$2} without losing original dimensions',
      () async {
        final decoded = await decodeLabelImage(await _png(size.$1, size.$2));
        try {
          expect(decoded.sourceWidth, size.$1);
          expect(decoded.sourceHeight, size.$2);
          expect(decoded.image.width, size.$3);
          expect(decoded.image.height, size.$4);
          // The returned image remains usable after the helper releases its codec.
          final pixels = (await decoded.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          expect(pixels.getUint32(0), 0x000000ff);
          expect(pixels.getUint32(pixels.lengthInBytes - 4), 0xffffffff);
        } finally {
          decoded.image.dispose();
        }
      },
    );
  }

  test('does not upscale a small image', () async {
    final decoded = await decodeLabelImage(await _png(11, 7));
    try {
      expect(decoded.sourceWidth, 11);
      expect(decoded.sourceHeight, 7);
      expect(decoded.image.width, 11);
      expect(decoded.image.height, 7);
    } finally {
      decoded.image.dispose();
    }
  });

  test(
    'custom bound keeps an extreme aspect ratio at least one pixel wide',
    () async {
      final decoded = await decodeLabelImage(
        await _png(1, 1025),
        maxDimension: 64,
      );
      try {
        expect(decoded.sourceWidth, 1);
        expect(decoded.sourceHeight, 1025);
        expect(decoded.image.width, 1);
        expect(decoded.image.height, 64);
      } finally {
        decoded.image.dispose();
      }
    },
  );

  test('invalid encoded bytes propagate a decode exception', () async {
    await expectLater(
      decodeLabelImage(Uint8List.fromList([0x89, 0x50, 0x4e, 0x47])),
      throwsA(isA<Exception>()),
    );
  });

  test('nonpositive decode bound is rejected', () async {
    await expectLater(
      decodeLabelImage(Uint8List(0), maxDimension: 0),
      throwsArgumentError,
    );
  });
}
