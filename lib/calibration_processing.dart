import 'dart:typed_data';

import 'calibration_photo_analysis.dart';

class CalibrationImageSettings {
  const CalibrationImageSettings({this.brightness = 0, this.contrast = 1});

  static const double minBrightness = -80;
  static const double maxBrightness = 80;
  static const double minContrast = .5;
  static const double maxContrast = 2;

  final double brightness;
  final double contrast;
}

/// Applies the detector's luminance first, then contrast about 128 and brightness.
/// Alpha is unchanged; the caller retains ownership of the original pixels.
Uint8List adjustCalibrationRgba(
  Uint8List rgba,
  int width,
  int height,
  CalibrationImageSettings settings,
) {
  if (width <= 0 ||
      height <= 0 ||
      width > 1800 ||
      height > 1800 ||
      rgba.length != width * height * 4) {
    throw ArgumentError(
      'Invalid calibration RGBA dimensions or buffer length.',
    );
  }
  if (!settings.brightness.isFinite ||
      settings.brightness < CalibrationImageSettings.minBrightness ||
      settings.brightness > CalibrationImageSettings.maxBrightness ||
      !settings.contrast.isFinite ||
      settings.contrast < CalibrationImageSettings.minContrast ||
      settings.contrast > CalibrationImageSettings.maxContrast) {
    throw ArgumentError('Calibration brightness or contrast is out of range.');
  }
  final output = Uint8List(rgba.length);
  // A lookup table keeps the per-pixel adjustment identical for still and live
  // frames without repeating floating-point operations for every channel.
  final levels = Uint8List(256);
  for (var value = 0; value < levels.length; value++) {
    levels[value] =
        ((value - 128) * settings.contrast + 128 + settings.brightness)
            .round()
            .clamp(0, 255)
            .toInt();
  }
  for (var i = 0; i < rgba.length; i += 4) {
    final value = levels[calibrationLuma(rgba[i], rgba[i + 1], rgba[i + 2])];
    output[i] = output[i + 1] = output[i + 2] = value;
    output[i + 3] = rgba[i + 3];
  }
  return output;
}

class CalibrationLiveInput {
  const CalibrationLiveInput({
    required this.rgba,
    required this.width,
    required this.height,
    required this.referenceRows,
    required this.settings,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final int referenceRows;
  final CalibrationImageSettings settings;
}

class CalibrationLiveResult {
  const CalibrationLiveResult({
    required this.processedRgba,
    required this.maskRgba,
    required this.width,
    required this.height,
    required this.analysis,
    required this.guidance,
  });

  final Uint8List processedRgba;
  final Uint8List maskRgba;
  final int width;
  final int height;
  final CalibrationPhotoAnalysis? analysis;
  final String? guidance;
}

/// Engine-free entry point for a worker isolate. Input is already oriented.
CalibrationLiveResult processCalibrationLiveFrame(CalibrationLiveInput input) {
  final processed = adjustCalibrationRgba(
    input.rgba,
    input.width,
    input.height,
    input.settings,
  );
  final inspection = inspectCalibrationPhoto(
    processed,
    input.width,
    input.height,
    referenceRows: input.referenceRows,
  );
  return CalibrationLiveResult(
    processedRgba: processed,
    maskRgba: inspection.maskRgba,
    width: input.width,
    height: input.height,
    analysis: inspection.analysis,
    guidance: inspection.guidance,
  );
}
