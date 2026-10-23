import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;

/// A bounded image and its original dimensions, before target-size rounding.
/// The caller owns [image] and must dispose it.
class DecodedLabelImage {
  const DecodedLabelImage({
    required this.image,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final ui.Image image;
  final int sourceWidth;
  final int sourceHeight;
}

/// Decodes the first frame without upscaling, bounding its longest edge and area.
///
/// Native decoding reads descriptor metadata and requests a bounded frame.
/// Web encoded descriptors do not expose dimensions. Flutter's web
/// instantiateImageCodecWithSize callback decodes twice, so instead we decode
/// once and downsample that frame if necessary. This bounds the returned image,
/// but the web decoder can still allocate a full-resolution source frame.
Future<DecodedLabelImage> decodeLabelImage(
  Uint8List bytes, {
  int maxDimension = 512,
  int? maxPixels,
}) async {
  if (maxDimension < 1) {
    throw ArgumentError.value(maxDimension, 'maxDimension', 'Must be positive');
  }
  if (maxPixels != null && maxPixels < 1) {
    throw ArgumentError.value(maxPixels, 'maxPixels', 'Must be positive');
  }

  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  late int sourceWidth;
  late int sourceHeight;
  try {
    if (kIsWeb) {
      codec = await ui.instantiateImageCodec(bytes);
    } else {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      sourceWidth = descriptor.width;
      sourceHeight = descriptor.height;
      final target = _targetSize(
        sourceWidth,
        sourceHeight,
        maxDimension,
        maxPixels,
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: target.width,
        targetHeight: target.height,
      );
    }
    image = (await codec.getNextFrame()).image;
    if (kIsWeb) {
      sourceWidth = image.width;
      sourceHeight = image.height;
      final target = _targetSize(
        sourceWidth,
        sourceHeight,
        maxDimension,
        maxPixels,
      );
      if (target.width != sourceWidth || target.height != sourceHeight) {
        final resized = await _resizeImage(image, target.width, target.height);
        image.dispose();
        image = resized;
      }
    }
    return DecodedLabelImage(
      image: image,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
  } catch (_) {
    image?.dispose();
    rethrow;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

({int width, int height}) _targetSize(
  int width,
  int height,
  int maxDimension,
  int? maxPixels,
) {
  var factor = math.min(1.0, maxDimension / math.max(width, height));
  if (maxPixels != null) {
    factor = math.min(factor, math.sqrt(maxPixels / (width * height)));
  }
  var targetWidth = math.max(1, (width * factor).round());
  var targetHeight = math.max(1, (height * factor).round());
  if (maxPixels != null) {
    targetWidth = math.min(targetWidth, maxPixels);
    targetHeight = math.min(targetHeight, maxPixels ~/ targetWidth);
  }
  return (width: targetWidth, height: targetHeight);
}

Future<ui.Image> _resizeImage(ui.Image source, int width, int height) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    source,
    ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}
