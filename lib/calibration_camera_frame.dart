import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// Camera stream APIs do not expose Android's image data-space/range metadata.
/// Android YUV uses the nominal video range; full-range sources can opt out.
enum CalibrationLumaRange { limited, full }

class CalibrationCameraFrame {
  const CalibrationCameraFrame(this.rgba, this.width, this.height);

  final Uint8List rgba;
  final int width;
  final int height;
}

/// Retains only the sampled plane, not unused chroma buffers, across isolates.
class CalibrationCameraFrameSource {
  CalibrationCameraFrameSource.fromImage(CameraImage image)
    : width = image.width,
      height = image.height,
      format = image.format.group,
      plane = image.planes.firstOrNull;

  final int width, height;
  final ImageFormatGroup format;
  final Plane? plane;
}

/// Clockwise rotation for the back-facing sensor, matching CameraPreview.
int calibrationCameraRotation(
  int sensorOrientation,
  DeviceOrientation orientation,
) {
  final deviceDegrees = switch (orientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  return (sensorOrientation - deviceDegrees + 360) % 360;
}

final _videoLuma = Uint8List.fromList([
  for (var value = 0; value < 256; value++)
    ((value - 16) * 255 / 219).round().clamp(0, 255).toInt(),
]);

/// Reads only selected pixels into a single orientation-correct, bounded buffer.
/// YUV420/NV21 need only their Y plane for the grayscale calibration detector.
CalibrationCameraFrame convertCalibrationCameraFrame(
  CalibrationCameraFrameSource image, {
  required int rotationDegrees,
  CalibrationLumaRange lumaRange = CalibrationLumaRange.limited,
}) {
  if (rotationDegrees != 0 &&
      rotationDegrees != 90 &&
      rotationDegrees != 180 &&
      rotationDegrees != 270) {
    throw ArgumentError.value(rotationDegrees, 'rotationDegrees');
  }
  final bgra = image.format == ImageFormatGroup.bgra8888;
  if (!bgra &&
      image.format != ImageFormatGroup.yuv420 &&
      image.format != ImageFormatGroup.nv21) {
    throw UnsupportedError('Camera stream format ${image.format.name}');
  }
  if (image.width < 1 || image.height < 1 || image.plane == null) {
    throw const FormatException('Empty camera stream frame');
  }
  final plane = image.plane!;
  final stride = plane.bytesPerPixel ?? (bgra ? 4 : 1);
  final bytesPerPixel = bgra ? 4 : 1;
  if (stride < bytesPerPixel ||
      plane.bytesPerRow < (image.width - 1) * stride + bytesPerPixel ||
      plane.bytes.length <
          (image.height - 1) * plane.bytesPerRow +
              (image.width - 1) * stride +
              bytesPerPixel) {
    throw const FormatException('Truncated camera stream plane');
  }
  final swapped = rotationDegrees == 90 || rotationDegrees == 270;
  final sourceWidth = swapped ? image.height : image.width;
  final sourceHeight = swapped ? image.width : image.height;
  final factor = math.min(1.0, 1600 / math.max(sourceWidth, sourceHeight));
  final width = math.max(1, (sourceWidth * factor).round());
  final height = math.max(1, (sourceHeight * factor).round());
  final output = Uint8List(width * height * 4);
  final expandLuma = lumaRange == CalibrationLumaRange.limited;
  for (var y = 0; y < height; y++) {
    final orientedY = math.min(
      sourceHeight - 1,
      ((y + .5) * sourceHeight / height).floor(),
    );
    for (var x = 0; x < width; x++) {
      final orientedX = math.min(
        sourceWidth - 1,
        ((x + .5) * sourceWidth / width).floor(),
      );
      final int sourceX, sourceY;
      switch (rotationDegrees) {
        case 90:
          sourceX = orientedY;
          sourceY = image.height - 1 - orientedX;
        case 180:
          sourceX = image.width - 1 - orientedX;
          sourceY = image.height - 1 - orientedY;
        case 270:
          sourceX = image.width - 1 - orientedY;
          sourceY = orientedX;
        default:
          sourceX = orientedX;
          sourceY = orientedY;
      }
      final input = sourceY * plane.bytesPerRow + sourceX * stride;
      final target = (y * width + x) * 4;
      if (bgra) {
        output[target] = plane.bytes[input + 2];
        output[target + 1] = plane.bytes[input + 1];
        output[target + 2] = plane.bytes[input];
        output[target + 3] = plane.bytes[input + 3];
      } else {
        final value = expandLuma
            ? _videoLuma[plane.bytes[input]]
            : plane.bytes[input];
        output[target] = value;
        output[target + 1] = value;
        output[target + 2] = value;
        output[target + 3] = 255;
      }
    }
  }
  return CalibrationCameraFrame(output, width, height);
}
