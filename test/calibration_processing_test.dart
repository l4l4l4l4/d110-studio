import 'dart:typed_data';

import 'package:d110_studio/calibration_photo_analysis.dart';
import 'package:d110_studio/calibration_processing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'identity uses detector luma and preserves alpha without mutating input',
    () {
      final rgba = Uint8List.fromList([
        255,
        0,
        0,
        255,
        0,
        255,
        0,
        128,
        0,
        0,
        255,
        0,
        127,
        127,
        127,
        249,
      ]);
      final before = Uint8List.fromList(rgba);
      final adjusted = adjustCalibrationRgba(
        rgba,
        4,
        1,
        const CalibrationImageSettings(),
      );
      expect(adjusted, [
        76,
        76,
        76,
        255,
        149,
        149,
        149,
        128,
        28,
        28,
        28,
        0,
        127,
        127,
        127,
        249,
      ]);
      expect(rgba, before);
      expect(identical(adjusted, rgba), isFalse);
    },
  );

  test(
    'brightness and contrast use bounded grayscale with unchanged alpha',
    () {
      final rgba = Uint8List.fromList([
        0,
        0,
        0,
        3,
        128,
        128,
        128,
        127,
        255,
        255,
        255,
        254,
      ]);
      expect(
        adjustCalibrationRgba(
          rgba,
          3,
          1,
          const CalibrationImageSettings(brightness: 80, contrast: 2),
        ),
        [0, 0, 0, 3, 208, 208, 208, 127, 255, 255, 255, 254],
      );
      expect(
        adjustCalibrationRgba(
          rgba,
          3,
          1,
          const CalibrationImageSettings(brightness: -80, contrast: .5),
        ),
        [0, 0, 0, 3, 48, 48, 48, 127, 112, 112, 112, 254],
      );
    },
  );

  test('invalid settings and RGBA shape stay errors rather than guidance', () {
    final rgba = _frame();
    for (final settings in [
      const CalibrationImageSettings(brightness: -80.01),
      const CalibrationImageSettings(brightness: 80.01),
      const CalibrationImageSettings(contrast: .49),
      const CalibrationImageSettings(contrast: 2.01),
      const CalibrationImageSettings(brightness: double.nan),
      const CalibrationImageSettings(contrast: double.infinity),
    ]) {
      expect(
        () => adjustCalibrationRgba(rgba, 128, 128, settings),
        throwsArgumentError,
      );
      expect(
        () => processCalibrationLiveFrame(
          CalibrationLiveInput(
            rgba: rgba,
            width: 128,
            height: 128,
            referenceRows: 80,
            settings: settings,
          ),
        ),
        throwsArgumentError,
      );
    }
    for (final size in [(0, 128), (-1, 128), (128, 127), (1801, 128)]) {
      expect(
        () => adjustCalibrationRgba(
          rgba,
          size.$1,
          size.$2,
          const CalibrationImageSettings(),
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => processCalibrationLiveFrame(
        CalibrationLiveInput(
          rgba: Uint8List(3),
          width: 128,
          height: 128,
          referenceRows: 80,
          settings: const CalibrationImageSettings(),
        ),
      ),
      throwsArgumentError,
    );
    expect(
      () => processCalibrationLiveFrame(
        CalibrationLiveInput(
          rgba: rgba,
          width: 128,
          height: 128,
          referenceRows: 47,
          settings: const CalibrationImageSettings(),
        ),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => inspectCalibrationPhoto(Uint8List(3), 128, 128, referenceRows: 80),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => inspectCalibrationPhoto(rgba, 128, 128, referenceRows: 1201),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'live preview and final photo use identical adjusted pixels and mask',
    () {
      final rgba = _frame();
      const settings = CalibrationImageSettings(brightness: -21, contrast: 1.3);
      final finalPixels = adjustCalibrationRgba(rgba, 128, 128, settings);
      final preview = processCalibrationLiveFrame(
        CalibrationLiveInput(
          rgba: rgba,
          width: 128,
          height: 128,
          referenceRows: 80,
          settings: settings,
        ),
      );
      final finalInspection = inspectCalibrationPhoto(
        finalPixels,
        128,
        128,
        referenceRows: 80,
      );
      expect(preview.processedRgba, finalPixels);
      expect(preview.maskRgba, finalInspection.maskRgba);
      expect(preview.width, 128);
      expect(preview.height, 128);
      expect(preview.analysis, isNull);
      expect(preview.guidance, finalInspection.guidance);
      expect(preview.guidance, isNotEmpty);
    },
  );

  test('uniform and multiple-paper frames never invent measured geometry', () {
    for (final rgba in [_frame(uniform: true), _frame(secondPaper: true)]) {
      final result = processCalibrationLiveFrame(
        CalibrationLiveInput(
          rgba: rgba,
          width: 128,
          height: 128,
          referenceRows: 80,
          settings: const CalibrationImageSettings(),
        ),
      );
      expect(result.analysis, isNull);
      expect(result.guidance, isNotEmpty);
      expect(result.maskRgba, hasLength(rgba.length));
    }
  });

  test('mask distinguishes actual paper, ink and muted background', () {
    final rgba = _frame();
    final inspection = inspectCalibrationPhoto(
      rgba,
      128,
      128,
      referenceRows: 80,
      measure: false,
    );
    expect(inspection.guidance, isNull);
    expect(inspection.analysis, isNull);
    expect(inspection.inkThreshold, inExclusiveRange(20, 240));
    expect(inspection.paperThreshold, inExclusiveRange(20, 240));
    int mask(int x, int y) => inspection.maskRgba[(y * 128 + x) * 4];
    expect(mask(40, 40), 255);
    expect(mask(62, 62), 0);
    expect(mask(2, 2), inExclusiveRange(0, 255));
    for (var i = 0; i < rgba.length; i += 4) {
      expect(inspection.maskRgba[i + 1], inspection.maskRgba[i]);
      expect(inspection.maskRgba[i + 2], inspection.maskRgba[i]);
      expect(inspection.maskRgba[i + 3], 255);
    }
  });

  test(
    'mask follows detected populations rather than a fixed brightness cut',
    () {
      final bright = _frame();
      final dim = Uint8List.fromList(bright);
      for (var i = 0; i < dim.length; i += 4) {
        if (dim[i] == 240) {
          dim[i] = dim[i + 1] = dim[i + 2] = 140;
        }
      }
      final brightInspection = inspectCalibrationPhoto(
        bright,
        128,
        128,
        referenceRows: 80,
        measure: false,
      );
      final dimInspection = inspectCalibrationPhoto(
        dim,
        128,
        128,
        referenceRows: 80,
        measure: false,
      );
      expect(brightInspection.guidance, isNull);
      expect(dimInspection.guidance, isNull);
      expect(brightInspection.inkThreshold, 130);
      expect(dimInspection.inkThreshold, 80);
      expect(dimInspection.maskRgba, brightInspection.maskRgba);
    },
  );

  test('failed segmentation shows muted pixels, not an invented threshold', () {
    final inspection = inspectCalibrationPhoto(
      _frame(uniform: true),
      128,
      128,
      referenceRows: 80,
    );
    expect(inspection.inkThreshold, isNull);
    expect(inspection.paperThreshold, isNull);
    expect(inspection.analysis, isNull);
    expect(inspection.guidance, contains('контраста'));
    expect(inspection.maskRgba.toSet(), {72, 255});
  });
}

Uint8List _frame({bool uniform = false, bool secondPaper = false}) {
  final rgba = Uint8List(128 * 128 * 4);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      final paper = secondPaper
          ? (x >= 6 && x < 58 || x >= 70 && x < 122) && y >= 20 && y < 108
          : x >= 20 && x < 108 && y >= 20 && y < 108;
      final ink = !secondPaper && x >= 59 && x < 67 && y >= 59 && y < 67;
      final value = uniform
          ? 128
          : paper && !ink
          ? 240
          : 20;
      final i = (y * 128 + x) * 4;
      rgba[i] = rgba[i + 1] = rgba[i + 2] = value;
      rgba[i + 3] = 255;
    }
  }
  return rgba;
}
