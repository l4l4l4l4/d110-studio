import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:d110_studio/raster.dart';

Uint8List pixels(List<int> shades) => Uint8List.fromList([
  for (final value in shades) ...[value, value, value, 255],
]);

void main() {
  test('transparent black composites onto white before thresholding', () {
    final result = monochromeRgba(
      Uint8List.fromList([0, 0, 0, 0]),
      1,
      1,
      const RasterSettings(),
    );
    expect(result, [255, 255, 255, 255]);
  });
  test('threshold boundary and inversion are deterministic', () {
    final source = pixels([127, 128, 129]);
    expect(
      monochromeRgba(source, 3, 1, const RasterSettings()),
      pixels([0, 255, 255]),
    );
    expect(
      monochromeRgba(source, 3, 1, const RasterSettings(invert: true)),
      pixels([255, 0, 0]),
    );
  });
  test('diffusion retains endpoints and does not wrap across rows', () {
    final source = pixels([0, 255, 0, 255]);
    expect(
      monochromeRgba(
        source,
        2,
        2,
        const RasterSettings(mode: RasterMode.diffusion),
      ),
      source,
    );
  });
  test('Sobel leaves a flat white image white', () {
    final source = pixels(List.filled(25, 180));
    expect(
      monochromeRgba(
        source,
        5,
        5,
        const RasterSettings(mode: RasterMode.edges),
      ),
      pixels(List.filled(25, 255)),
    );
  });
  test('Sobel renders a vertical boundary black on white', () {
    final source = pixels([
      for (var y = 0; y < 5; y++) ...[0, 0, 255, 255, 255],
    ]);
    final result = monochromeRgba(
      source,
      5,
      5,
      const RasterSettings(mode: RasterMode.edges, threshold: 128),
    );
    expect(result[(2 * 5 + 1) * 4], 0);
    expect(result[(2 * 5 + 3) * 4], 255);
  });
  test('packing uses MSB first, black is one, and pads white', () {
    expect(
      packMonochrome(pixels([0, 255, 0, 255, 255, 255, 255, 0, 0]), 9, 1),
      [0xa1, 0x80],
    );
  });
  test('quarter turn maps coordinates without interpolation', () {
    final packed = rotateForPrinter(pixels([0, 255, 255, 255, 0, 255]), 3, 2);
    expect(packed.width, 2);
    expect(packed.height, 3);
    expect(packed.rgba, pixels([255, 0, 0, 255, 255, 255]));
  });
}
