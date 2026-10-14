import 'dart:math' as math;
import 'dart:typed_data';

enum RasterMode { threshold, ordered, diffusion, edges }

class RasterSettings {
  const RasterSettings({
    this.mode = RasterMode.threshold,
    this.threshold = 128,
    this.brightness = 0,
    this.contrast = 1,
    this.invert = false,
  }) : assert(threshold >= 0 && threshold <= 255),
       assert(brightness >= -100 && brightness <= 100),
       assert(contrast >= 0.2 && contrast <= 3);

  final RasterMode mode;
  final int threshold;
  final double brightness;
  final double contrast;
  final bool invert;

  RasterSettings copyWith({
    RasterMode? mode,
    int? threshold,
    double? brightness,
    double? contrast,
    bool? invert,
  }) => RasterSettings(
    mode: mode ?? this.mode,
    threshold: threshold ?? this.threshold,
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    invert: invert ?? this.invert,
  );

  Map<String, Object> toJson() => {
    'mode': mode.name,
    'threshold': threshold,
    'brightness': brightness,
    'contrast': contrast,
    'invert': invert,
  };

  factory RasterSettings.fromJson(Map<String, dynamic> json) {
    final modeValue = json['mode'] ?? 'threshold';
    final thresholdValue = json['threshold'] ?? 128;
    final brightnessValue = json['brightness'] ?? 0;
    final contrastValue = json['contrast'] ?? 1;
    final invertValue = json['invert'] ?? false;
    RasterMode? mode;
    for (final candidate in RasterMode.values) {
      if (candidate.name == modeValue) mode = candidate;
    }
    if (mode == null ||
        thresholdValue is! int ||
        thresholdValue < 0 ||
        thresholdValue > 255 ||
        brightnessValue is! num ||
        !brightnessValue.isFinite ||
        brightnessValue < -100 ||
        brightnessValue > 100 ||
        contrastValue is! num ||
        !contrastValue.isFinite ||
        contrastValue < 0.2 ||
        contrastValue > 3 ||
        invertValue is! bool) {
      throw const FormatException('Invalid raster settings');
    }
    return RasterSettings(
      mode: mode,
      threshold: thresholdValue,
      brightness: brightnessValue.toDouble(),
      contrast: contrastValue.toDouble(),
      invert: invertValue,
    );
  }
}

// Bound both total work and row-buffer allocations for decoded images.
const int _maxDimension = 16384;
const int _maxPixels = 16 * 1024 * 1024;

void _validateImage(Uint8List rgba, int width, int height) {
  if (width < 1 ||
      height < 1 ||
      width > _maxDimension ||
      height > _maxDimension ||
      width * height > _maxPixels) {
    throw ArgumentError('Image dimensions must be positive and bounded');
  }
  if (rgba.length != width * height * 4) {
    throw ArgumentError('RGBA buffer length does not match image dimensions');
  }
}

void _validateSettings(RasterSettings settings) {
  if (settings.threshold < 0 ||
      settings.threshold > 255 ||
      !settings.brightness.isFinite ||
      settings.brightness < -100 ||
      settings.brightness > 100 ||
      !settings.contrast.isFinite ||
      settings.contrast < 0.2 ||
      settings.contrast > 3) {
    throw ArgumentError('Raster settings are out of range');
  }
}

double _luminance(Uint8List rgba, int offset, RasterSettings settings) {
  final alpha = rgba[offset + 3];
  // Integer weights sum to 1000, preserving exact grayscale boundaries.
  final weighted =
      rgba[offset] * 299 + rgba[offset + 1] * 587 + rgba[offset + 2] * 114;
  final gray = (weighted * alpha + 255000 * (255 - alpha)) / 255000;
  return ((gray - 128) * settings.contrast + 128 + settings.brightness * 2.55)
      .clamp(0.0, 255.0)
      .toDouble();
}

void _pixel(Uint8List output, int offset, bool black, bool invert) {
  final value = black != invert ? 0 : 255;
  output[offset] = value;
  output[offset + 1] = value;
  output[offset + 2] = value;
  output[offset + 3] = 255;
}

const _bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5];

/// Composites on white and returns opaque, black-or-white RGBA pixels.
/// Threshold comparison is strict; inversion is applied after each mode.
Uint8List monochromeRgba(
  Uint8List rgba,
  int width,
  int height,
  RasterSettings settings,
) {
  _validateImage(rgba, width, height);
  _validateSettings(settings);
  final output = Uint8List(rgba.length);
  switch (settings.mode) {
    case RasterMode.threshold:
    case RasterMode.ordered:
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final offset = (y * width + x) * 4;
          final gray = _luminance(rgba, offset, settings);
          final threshold = settings.mode == RasterMode.ordered
              ? (settings.threshold +
                        ((_bayer[(y & 3) * 4 + (x & 3)] + 0.5) / 16 - 0.5) *
                            255)
                    .clamp(0.0, 255.0)
              : settings.threshold;
          _pixel(output, offset, gray < threshold, settings.invert);
        }
      }
      break;
    case RasterMode.diffusion:
      var current = Float64List(width + 2);
      var next = Float64List(width + 2);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          final offset = (y * width + x) * 4;
          final gray = (_luminance(rgba, offset, settings) + current[x + 1])
              .clamp(0.0, 255.0);
          final black = gray < settings.threshold;
          _pixel(output, offset, black, settings.invert);
          final error = gray - (black ? 0 : 255);
          // Padding absorbs off-image contributions; it is never read.
          current[x + 2] += error * (7 / 16);
          next[x] += error * (3 / 16);
          next[x + 1] += error * (5 / 16);
          next[x + 2] += error * (1 / 16);
        }
        final spare = current;
        current = next;
        next = spare;
        next.fillRange(0, next.length, 0);
      }
      break;
    case RasterMode.edges:
      _sobel(rgba, width, height, settings, output);
      break;
  }
  return output;
}

void _grayRow(
  Uint8List rgba,
  int width,
  int y,
  RasterSettings settings,
  Float64List row,
) {
  var offset = y * width * 4;
  for (var x = 0; x < width; x++, offset += 4) {
    row[x] = _luminance(rgba, offset, settings);
  }
}

void _sobel(
  Uint8List rgba,
  int width,
  int height,
  RasterSettings settings,
  Uint8List output,
) {
  var above = Float64List(width);
  var center = Float64List(width);
  var below = Float64List(width);
  _grayRow(rgba, width, 0, settings, above);
  center.setRange(0, width, above);
  _grayRow(rgba, width, height > 1 ? 1 : 0, settings, below);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      // Replicated borders prevent artificial edges on uniform images.
      final left = x > 0 ? x - 1 : 0;
      final right = x + 1 < width ? x + 1 : width - 1;
      final gx =
          above[right] -
          above[left] +
          2 * (center[right] - center[left]) +
          below[right] -
          below[left];
      final gy =
          below[left] -
          above[left] +
          2 * (below[x] - above[x]) +
          below[right] -
          above[right];
      // Maximum magnitude is bounded by the Sobel kernel's 4x scale.
      final magnitude = math.sqrt(gx * gx + gy * gy) / 4;
      _pixel(
        output,
        (y * width + x) * 4,
        magnitude > settings.threshold,
        settings.invert,
      );
    }
    if (y + 1 < height) {
      final spare = above;
      above = center;
      center = below;
      below = spare;
      _grayRow(rgba, width, math.min(y + 2, height - 1), settings, below);
    }
  }
}

/// Packs black pixels as one bits, MSB first, with white row padding.
Uint8List packMonochrome(Uint8List rgba, int width, int height) {
  _validateImage(rgba, width, height);
  final stride = (width + 7) ~/ 8;
  final packed = Uint8List(stride * height);
  const settings = RasterSettings();
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (_luminance(rgba, (y * width + x) * 4, settings) < 128) {
        packed[y * stride + (x >> 3)] |= 0x80 >> (x & 7);
      }
    }
  }
  return packed;
}

class PrinterRaster {
  PrinterRaster({
    required this.width,
    required this.height,
    required this.rgba,
  }) {
    _validateImage(rgba, width, height);
  }

  final int width;
  final int height;
  final Uint8List rgba;

  Uint8List get packed => packMonochrome(rgba, width, height);
}

/// Rotates exactly 90 degrees clockwise: (x, y) -> (height - 1 - y, x).
PrinterRaster rotateForPrinter(Uint8List rgba, int width, int height) {
  _validateImage(rgba, width, height);
  final rotated = Uint8List(rgba.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final source = (y * width + x) * 4;
      final target = (x * height + height - 1 - y) * 4;
      rotated[target] = rgba[source];
      rotated[target + 1] = rgba[source + 1];
      rotated[target + 2] = rgba[source + 2];
      rotated[target + 3] = rgba[source + 3];
    }
  }
  return PrinterRaster(width: height, height: width, rgba: rotated);
}
