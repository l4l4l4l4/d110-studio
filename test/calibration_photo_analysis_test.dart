import 'dart:math' as math;
import 'dart:typed_data';

import 'package:d110_studio/calibration_photo_analysis.dart';
import 'package:d110_studio/calibration_processing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'inspection and measurement share segmentation and real contour pixels',
    () {
      final photo = _Photo(
        rows: 80,
        thickMarks: true,
        ink: 150,
        glare: true,
        matrix: [0, -2.2, 700, 2.2, 0, 220, 0, 0, 1],
      );
      final rgba = _blur(photo, 2);
      final maskOnly = inspectCalibrationPhoto(
        rgba,
        photo.width,
        photo.height,
        referenceRows: photo.rows,
        measure: false,
      );
      final inspected = inspectCalibrationPhoto(
        rgba,
        photo.width,
        photo.height,
        referenceRows: photo.rows,
      );
      final measured = analyzeCalibrationPhoto(
        rgba,
        photo.width,
        photo.height,
        referenceRows: photo.rows,
      );
      expect(inspected.guidance, isNull);
      expect(inspected.maskRgba, maskOnly.maskRgba);
      expect(inspected.inkThreshold, maskOnly.inkThreshold);
      expect(inspected.paperThreshold, maskOnly.paperThreshold);
      expect(
        inspected.paperThreshold,
        greaterThanOrEqualTo(inspected.inkThreshold!),
      );
      final analysis = inspected.analysis!;
      _expectGeometry(analysis, photo);
      expect(analysis.lengthMm, measured.lengthMm);
      expect(analysis.widthMm, measured.widthMm);
      expect(analysis.radiusMm, measured.radiusMm);
      expect(
        [
          for (final p in analysis.paperOutline) [p.x, p.y],
        ],
        [
          for (final p in measured.paperOutline) [p.x, p.y],
        ],
      );
      var inkPixels = 0, paperPixels = 0, mutedPixels = 0;
      for (var i = 0; i < rgba.length; i += 4) {
        switch (inspected.maskRgba[i]) {
          case 0:
            expect(rgba[i], lessThan(inspected.inkThreshold!));
            inkPixels++;
          case 255:
            expect(rgba[i], greaterThanOrEqualTo(inspected.inkThreshold!));
            paperPixels++;
          default:
            mutedPixels++;
        }
      }
      expect(inkPixels, greaterThan(100));
      expect(paperPixels, greaterThan(2000));
      expect(mutedPixels, greaterThan(2000));
    },
  );

  test('identity transform retains detector thresholds and exact geometry', () {
    final photo = _Photo();
    // A colored image whose red channel differs from detector luminance.
    final colored = Uint8List.fromList(photo.rgba);
    for (var i = 0; i < colored.length; i += 4) {
      colored[i] = (colored[i] + 12).clamp(0, 255).toInt();
      colored[i + 2] = (colored[i + 2] - 12).clamp(0, 255).toInt();
    }
    final gray = adjustCalibrationRgba(
      colored,
      photo.width,
      photo.height,
      const CalibrationImageSettings(),
    );
    final before = inspectCalibrationPhoto(
      colored,
      photo.width,
      photo.height,
      referenceRows: photo.rows,
    );
    final after = inspectCalibrationPhoto(
      gray,
      photo.width,
      photo.height,
      referenceRows: photo.rows,
    );
    expect(before.guidance, isNull);
    expect(after.guidance, isNull);
    expect(before.maskRgba, after.maskRgba);
    expect(before.inkThreshold, after.inkThreshold);
    expect(before.paperThreshold, after.paperThreshold);
    expect(before.analysis!.lengthMm, after.analysis!.lengthMm);
    expect(before.analysis!.widthMm, after.analysis!.widthMm);
    expect(
      [
        for (final p in before.analysis!.paperOutline) [p.x, p.y],
      ],
      [
        for (final p in after.analysis!.paperOutline) [p.x, p.y],
      ],
    );
  });

  test('ambiguous ruler orientation has guidance without nominal geometry', () {
    final photo = _Photo(ruler: false);
    final inspected = inspectCalibrationPhoto(
      photo.rgba,
      photo.width,
      photo.height,
      referenceRows: photo.rows,
    );
    expect(inspected.analysis, isNull);
    expect(inspected.guidance, isNotEmpty);
    expect(inspected.inkThreshold, isNotNull);
    expect(inspected.maskRgba, contains(0));
    expect(photo.analyze, throwsA(isA<FormatException>()));
  });

  test(
    'adjusted live and final photo retain the same accepted measurement',
    () {
      final photo = _Photo();
      const settings = CalibrationImageSettings(brightness: -10, contrast: 1.1);
      final live = processCalibrationLiveFrame(
        CalibrationLiveInput(
          rgba: photo.rgba,
          width: photo.width,
          height: photo.height,
          referenceRows: photo.rows,
          settings: settings,
        ),
      );
      final finalPixels = adjustCalibrationRgba(
        photo.rgba,
        photo.width,
        photo.height,
        settings,
      );
      final finalAnalysis = analyzeCalibrationPhoto(
        finalPixels,
        photo.width,
        photo.height,
        referenceRows: photo.rows,
      );
      expect(live.guidance, isNull);
      expect(live.processedRgba, finalPixels);
      expect(live.analysis!.lengthMm, finalAnalysis.lengthMm);
      expect(live.analysis!.widthMm, finalAnalysis.widthMm);
      expect(live.analysis!.radiusMm, finalAnalysis.radiusMm);
      expect(live.analysis!.feedOffsetDots, finalAnalysis.feedOffsetDots);
      expect(live.analysis!.headOffsetDots, finalAnalysis.headOffsetDots);
      expect(
        [
          for (final p in live.analysis!.paperOutline) [p.x, p.y],
        ],
        [
          for (final p in finalAnalysis.paperOutline) [p.x, p.y],
        ],
      );
    },
  );

  test('measures paper rather than the printed reference bounds', () {
    final photo = _Photo();
    final result = photo.analyze();
    _expectGeometry(result, photo);
    expect(result.lengthMm, isNot(closeTo(photo.rows / 8, 1)));
    expect(result.fiducials, hasLength(4));
    expect(result.paperOutline.length, greaterThan(12));
    for (var i = 0; i < 4; i++) {
      expect(result.fiducials[i].x, closeTo(photo.marks[i].x, 1.2));
      expect(result.fiducials[i].y, closeTo(photo.marks[i].y, 1.2));
    }
    for (final point in result.paperOutline) {
      expect(point.x, inInclusiveRange(0, photo.width.toDouble()));
      expect(point.y, inInclusiveRange(0, photo.height.toDouble()));
    }
    expect(result.edgeErrorDots, lessThan(1));
  });

  test('recovers projective dimensions, radius and signed offsets', () {
    for (final matrix in [
      [2.8, .45, 130.0, .35, 3.3, 95.0, .0009, -.0008, 1.0],
      // Same oblique view translated 40 image pixels left, leaving background
      // beyond the entire paper and its two-dot contrast sampling band.
      [2.216, -1.932, 260.0, 1.7, 2.4, 70.0, -.0004, .0008, 1.0],
      [-2.9, -.3, 780.0, .2, -3.5, 620.0, .0004, .0003, 1.0],
    ]) {
      final photo = _Photo(matrix: matrix, text: true);
      _expectGeometry(photo.analyze(), photo);
    }
  });

  test('supports another reference length without using it as paper size', () {
    final photo = _Photo(rows: 80, length: 23, radius: 1.25);
    _expectGeometry(photo.analyze(), photo);
  });

  test(
    'thick open crosses retain projective centroids and manual validation',
    () {
      for (final matrix in [
        [2.8, .45, 130.0, .35, 3.3, 95.0, .0009, -.0008, 1.0],
        [-2.9, -.3, 780.0, .2, -3.5, 620.0, .0004, .0003, 1.0],
      ]) {
        final photo = _Photo(thickMarks: true, rows: 80, matrix: matrix);
        final result = photo.analyze();
        _expectGeometry(result, photo);
        _expectGeometry(photo.analyze(manual: photo.marks), photo);
        for (var i = 0; i < 4; i++) {
          expect(result.fiducials[i].x, closeTo(photo.marks[i].x, 1.2));
          expect(result.fiducials[i].y, closeTo(photo.marks[i].y, 1.2));
        }
      }
    },
  );

  test(
    'gray thermal marks on a flash-lit background retain measured geometry',
    () {
      for (final matrix in [
        [0.0, -2.2, 700.0, 2.2, 0.0, 220.0, 0.0, 0.0, 1.0],
        [0.0, -2.2, 700.0, -2.2, 0.0, 740.0, 0.0, 0.0, 1.0],
      ]) {
        final photo = _Photo(
          rows: 80,
          thickMarks: true,
          ink: 150,
          glare: true,
          matrix: matrix,
        );
        final result = analyzeCalibrationPhoto(
          _blur(photo, 2),
          photo.width,
          photo.height,
          referenceRows: photo.rows,
        );
        _expectGeometry(result, photo);
        for (var i = 0; i < 4; i++) {
          expect(result.fiducials[i].x, closeTo(photo.marks[i].x, 1.2));
          expect(result.fiducials[i].y, closeTo(photo.marks[i].y, 1.2));
        }
      }
    },
  );

  test(
    'flash glare cannot invent ruler orientation when only crosses exist',
    () {
      final photo = _Photo(
        rows: 80,
        thickMarks: true,
        ink: 150,
        glare: true,
        ruler: false,
        matrix: [0, -2.2, 700, 2.2, 0, 220, 0, 0, 1],
      );
      expect(
        () => analyzeCalibrationPhoto(
          _blur(photo, 2),
          photo.width,
          photo.height,
          referenceRows: photo.rows,
        ),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('thick markers still reject centres covered by solid ink', () {
    final photo = _Photo(
      thickMarks: true,
      matrix: [4, 0, 130, 0, 4, 95, 0, 0, 1],
    );
    final point = photo.marks.first;
    for (var y = (point.y - 30).floor(); y < point.y + 30; y++) {
      for (var x = (point.x - 30).floor(); x < point.x + 30; x++) {
        final i = (y * photo.width + x) * 4;
        photo.rgba[i] = 19;
        photo.rgba[i + 1] = 19;
        photo.rgba[i + 2] = 19;
      }
    }
    expect(
      () => photo.analyze(manual: photo.marks),
      throwsA(isA<FormatException>()),
    );
  });

  test('paper starting after raster zero produces negative offsets', () {
    final photo = _Photo(feed: -4, head: -3);
    _expectGeometry(photo.analyze(), photo);
  });

  test('ruler phase disambiguates a reflected photograph', () {
    final photo = _Photo(matrix: [-2.8, .3, 780, .2, 3.5, 90, .0001, .0002, 1]);
    _expectGeometry(photo.analyze(), photo);
  });

  test(
    'edited profile outline uses the same projective raster coordinates',
    () {
      final matrix = [2.8, .45, 130.0, .35, 3.3, 95.0, .0009, -.0008, 1.0];
      final marks = [
        _project(matrix, 16.5, 16.5),
        _project(matrix, 143.5, 16.5),
        _project(matrix, 16.5, 56.5),
        _project(matrix, 143.5, 56.5),
      ];
      final outline = projectCalibrationPaperOutline(
        referenceRows: 160,
        fiducials: marks,
        lengthMm: 32,
        widthMm: 15,
        radiusMm: 3,
        feedOffsetDots: 8,
        headOffsetDots: -4,
      );
      expect(outline.length, greaterThanOrEqualTo(8));
      final inverse = _inverse(matrix);
      final world = [for (final p in outline) _project(inverse, p.x, p.y)];
      for (final p in world) {
        final qx = (p.x - 120).abs() - 128 + 24;
        final qy = (p.y - 64).abs() - 60 + 24;
        final distance =
            math.sqrt(
              math.pow(math.max(0, qx), 2) + math.pow(math.max(0, qy), 2),
            ) +
            math.min(math.max(qx, qy), 0) -
            24;
        expect(distance, closeTo(0, .02));
      }
      expect(world.map((p) => p.x).reduce(math.min), closeTo(-8, .02));
      expect(world.map((p) => p.x).reduce(math.max), closeTo(248, .02));
      expect(world.map((p) => p.y).reduce(math.min), closeTo(4, .02));
      expect(world.map((p) => p.y).reduce(math.max), closeTo(124, .02));
    },
  );

  test('edited outline rejects impossible radius and degenerate points', () {
    expect(
      () => projectCalibrationPaperOutline(
        referenceRows: 80,
        fiducials: List.filled(4, const CalibrationPhotoPoint(20, 20)),
        lengthMm: 30,
        widthMm: 14,
        radiusMm: 8,
        feedOffsetDots: 0,
        headOffsetDots: 0,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => projectCalibrationPaperOutline(
        referenceRows: 80,
        fiducials: List.filled(4, const CalibrationPhotoPoint(20, 20)),
        lengthMm: 30,
        widthMm: 14,
        radiusMm: 2,
        feedOffsetDots: 0,
        headOffsetDots: 0,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('printing and disconnected text do not become paper edges', () {
    final photo = _Photo(text: true, extraCross: true);
    _expectGeometry(photo.analyze(), photo);
  });

  test('manual taps recover ambiguous orientation without manual geometry', () {
    final photo = _Photo(ruler: false);
    expect(photo.analyze, throwsA(isA<FormatException>()));
    _expectGeometry(photo.analyze(manual: photo.marks), photo);
  });

  test('corrected subpixel taps still measure projective paper geometry', () {
    final photo = _Photo(ruler: false);
    final taps = [
      for (var i = 0; i < 4; i++)
        CalibrationPhotoPoint(
          photo.marks[i].x + (i.isEven ? .2 : -.2),
          photo.marks[i].y + (i < 2 ? -.15 : .15),
        ),
    ];
    _expectGeometry(photo.analyze(manual: taps), photo);
  });

  test(
    'legacy wrapped legend needs taps but retains measurable cross centres',
    () {
      final photo = _legacyOverlapPhoto();
      expect(
        photo.analyze,
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'merged cross cannot be selected automatically',
            contains('четыре креста'),
          ),
        ),
      );
      _expectGeometry(photo.analyze(manual: photo.marks), photo);
    },
  );

  test('manual taps cannot turn an ink-covered cross into a measurement', () {
    final photo = _legacyOverlapPhoto();
    // The legacy overlap leaves every one-dot arm intact. A solid 5-dot
    // square instead destroys the surrounding white stencil and must fail.
    for (var y = 336; y < 356; y++) {
      for (var x = 212; x < 232; x++) {
        final i = (y * photo.width + x) * 4;
        photo.rgba[i] = 19;
        photo.rgba[i + 1] = 19;
        photo.rgba[i + 2] = 19;
      }
    }
    expect(
      () => photo.analyze(manual: photo.marks),
      throwsA(isA<FormatException>()),
    );
  });

  test('four symmetric crosses alone never silently pick offset signs', () {
    final photo = _Photo(ruler: false);
    expect(
      photo.analyze,
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'actionable orientation error',
          contains('крест'),
        ),
      ),
    );
  });

  test('a confidently measured square corner can be zero', () {
    final photo = _Photo(radius: 0);
    final result = photo.analyze();
    expect(result.radiusMm, closeTo(0, .15));
    _expectGeometry(result, photo);
  });

  test('large round corners are fitted rather than a nominal radius', () {
    final photo = _Photo(radius: 5);
    _expectGeometry(photo.analyze(manual: photo.marks), photo);
  });

  test(
    'manual ordering measures narrow paper with a clipped printed ruler',
    () {
      final photo = _Photo(paperWidth: 9, radius: 1.2, head: 4, feed: 7);
      _expectGeometry(photo.analyze(manual: photo.marks), photo);
    },
  );

  test('missing marks are rejected even when supplied as manual positions', () {
    final photo = _Photo(missingMark: 2);
    expect(photo.analyze, throwsA(isA<FormatException>()));
    expect(
      () => photo.analyze(manual: photo.marks),
      throwsA(isA<FormatException>()),
    );
  });

  test('low contrast paper fails before any nominal geometry is returned', () {
    final photo = _Photo(background: 194, paper: 225);
    expect(photo.analyze, throwsA(isA<FormatException>()));
  });

  test('blurred crosses fail even when their exact centres are provided', () {
    final photo = _Photo();
    final blurred = _blur(photo, 8);
    expect(
      () => analyzeCalibrationPhoto(
        blurred,
        photo.width,
        photo.height,
        referenceRows: photo.rows,
        fiducials: photo.marks,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('under-resolved one-dot marks fail even with exact taps', () {
    final photo = _Photo(matrix: [1.05, .1, 120, .05, 1.1, 100, 0, 0, 1]);
    expect(
      () => photo.analyze(manual: photo.marks),
      throwsA(isA<FormatException>()),
    );
  });

  test('complete contour is required even if every cross is visible', () {
    final photo = _Photo(
      feed: 20,
      radius: .5,
      matrix: [3, 0, 30, 0, 3.5, 100, 0, 0, 1],
    );
    expect(
      () => photo.analyze(manual: photo.marks),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'whole paper without enough surrounding background fails explicitly',
    () {
      // True paper reaches X=895.219 in a 900px frame, but the required
      // two-dot exterior band reaches X=903.312. No paper or mark is clipped.
      final photo = _Photo(
        matrix: [2.2, -1.9, 300, 1.7, 2.4, 70, -.0004, .0008, 1],
      );
      expect(
        () => photo.analyze(manual: photo.marks),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'surrounding background guidance',
            contains('отступ'),
          ),
        ),
      );
    },
  );

  test('cut-off corner is not invented by a rounded-rectangle fit', () {
    final photo = _Photo(cutCorner: true);
    expect(
      () => photo.analyze(manual: photo.marks),
      throwsA(isA<FormatException>()),
    );
  });

  test('a concave torn edge cannot hide behind its convex hull', () {
    final photo = _Photo(notch: true);
    expect(
      () => photo.analyze(manual: photo.marks),
      throwsA(isA<FormatException>()),
    );
  });

  test('two plausible white sheets are explicitly ambiguous', () {
    final photo = _Photo(secondPaper: true);
    expect(photo.analyze, throwsA(isA<FormatException>()));
  });

  test(
    'manual taps cannot bypass crossed or degenerate projective geometry',
    () {
      final photo = _Photo();
      expect(
        () => photo.analyze(
          manual: [
            photo.marks[0],
            photo.marks[3],
            photo.marks[2],
            photo.marks[1],
          ],
        ),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => photo.analyze(manual: List.filled(4, photo.marks[0])),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('input dimensions, buffer length and reference range are bounded', () {
    expect(
      () => analyzeCalibrationPhoto(Uint8List(4), 100, 100, referenceRows: 80),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => analyzeCalibrationPhoto(Uint8List(0), 1801, 100, referenceRows: 80),
      throwsA(isA<FormatException>()),
    );
    final photo = _Photo();
    expect(
      () => analyzeCalibrationPhoto(
        photo.rgba,
        photo.width,
        photo.height,
        referenceRows: 0,
      ),
      throwsA(isA<FormatException>()),
    );
  });
}

void _expectGeometry(CalibrationPhotoAnalysis result, _Photo photo) {
  expect(result.lengthMm, closeTo(photo.length, .18));
  expect(result.widthMm, closeTo(photo.paperWidth, .18));
  expect(result.radiusMm, closeTo(photo.radius, .22));
  expect(result.feedOffsetDots, closeTo(photo.feed, 1));
  expect(result.headOffsetDots, closeTo(photo.head, 1));
}

_Photo _legacyOverlapPhoto() => _Photo(
  rows: 80,
  paperWidth: 12,
  radius: 1.5,
  feed: 4,
  head: 0,
  width: 1280,
  height: 720,
  legacyLegendOverlap: true,
  matrix: [4, 0, 156, 0, 4, 120, 0, 0, 1],
);

/// Independent inverse-rasterized photo: the detector never sees this matrix or
/// paper dimensions. Four subpixel samples, mild lighting gradient and noise
/// exercise actual image-space localization instead of feeding ideal contours.
class _Photo {
  _Photo({
    this.width = 900,
    this.height = 850,
    this.rows = 160,
    this.length = 30,
    this.paperWidth = 14,
    this.radius = 2,
    this.feed = 5,
    this.head = 7,
    this.ruler = true,
    this.text = false,
    this.extraCross = false,
    this.missingMark = -1,
    this.background = 28,
    this.paper = 239,
    this.ink = 19,
    this.cutCorner = false,
    this.secondPaper = false,
    this.notch = false,
    this.legacyLegendOverlap = false,
    this.thickMarks = false,
    this.glare = false,
    List<double>? matrix,
  }) : matrix = matrix ?? [2.8, .45, 130, .35, 3.3, 95, .0009, -.0008, 1] {
    final inverse = _inverse(this.matrix);
    rgba = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        var light = 0.0;
        for (var sy = 0; sy < 2; sy++) {
          for (var sx = 0; sx < 2; sx++) {
            final px = x + .25 + sx * .5, py = y + .25 + sy * .5;
            final z = inverse[6] * px + inverse[7] * py + inverse[8];
            final wx = (inverse[0] * px + inverse[1] * py + inverse[2]) / z;
            final wy = (inverse[3] * px + inverse[4] * py + inverse[5]) / z;
            var value = background.toDouble();
            if (glare) {
              final distance =
                  math.pow((px - 400) / 130, 2) + math.pow((py - 500) / 230, 2);
              value += 175 * math.exp(-distance / 2);
            }
            if (_onPaper(wx, wy)) {
              value = _printed(wx, wy) ? ink.toDouble() : paper.toDouble();
            }
            if (secondPaper && x > 30 && x < 260 && y > 630 && y < 810) {
              value = paper.toDouble();
            }
            light += value;
          }
        }
        final noise = ((x * 17 + y * 31) % 7) - 3;
        final value = (light / 4 - 7 * y / height + noise)
            .round()
            .clamp(0, 255)
            .toInt();
        final i = (y * width + x) * 4;
        rgba[i] = value;
        rgba[i + 1] = value;
        rgba[i + 2] = value;
        rgba[i + 3] = 255;
      }
    }
  }

  final int rows, feed, head, missingMark, background, paper, ink;
  final double length, paperWidth, radius;
  final bool ruler, text, extraCross, cutCorner, secondPaper, notch;
  final bool legacyLegendOverlap;
  final bool thickMarks;
  final bool glare;
  final List<double> matrix;
  final int width, height;
  late final Uint8List rgba;
  late final List<List<double>> _printCenters = [
    [16.5, 16.5],
    [rows - 16.5, 16.5],
    [16.5, 56.5],
    [rows - 16.5, 56.5],
    if (extraCross) [110.5, 77.5],
  ];

  List<CalibrationPhotoPoint> get marks => [
    _project(matrix, 16.5, 16.5),
    _project(matrix, rows - 16.5, 16.5),
    _project(matrix, 16.5, 56.5),
    _project(matrix, rows - 16.5, 56.5),
  ];

  CalibrationPhotoAnalysis analyze({List<CalibrationPhotoPoint>? manual}) =>
      analyzeCalibrationPhoto(
        rgba,
        width,
        height,
        referenceRows: rows,
        fiducials: manual,
      );

  bool _onPaper(double x, double y) {
    final left = -feed.toDouble(), top = -head.toDouble();
    final right = left + length * 8, bottom = top + paperWidth * 8;
    if (x < left || y < top || x >= right || y >= bottom) return false;
    if (cutCorner && x + y < left + top + 34) return false;
    if (notch && x < left + 10 && y > 35 && y < 55) return false;
    final cx = x.clamp(left + radius * 8, right - radius * 8);
    final cy = y.clamp(top + radius * 8, bottom - radius * 8);
    return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius * 64;
  }

  bool _printed(double x, double y) {
    for (var i = 0; i < _printCenters.length; i++) {
      if (i == missingMark) continue;
      final dx = (x - _printCenters[i][0]).abs();
      final dy = (y - _printCenters[i][1]).abs();
      final stroke = thickMarks ? 1.5 : .5;
      final arm = thickMarks ? 6.5 : 3.5;
      if ((dx < stroke && dy < arm) || (dy < stroke && dx < arm)) return true;
    }
    // Exact local ink topology of the old NotoSans legend's wrapped "mm",
    // observed in the real packed 80-row reference. Five dots merge into BL;
    // the sixth contributes the other unwanted sample in its 9x9 stencil.
    if (legacyLegendOverlap && x >= 13 && x < 20 && y >= 51 && y < 56) {
      final ix = x.floor(), iy = y.floor();
      if ((iy == 51 && ix == 15) ||
          (iy == 52 && (ix == 13 || ix == 16)) ||
          (ix == 19 && iy >= 53 && iy <= 55)) {
        return true;
      }
    }
    if (ruler && x >= 0 && x < rows && y >= 0 && y < 96) {
      final ix = x.floor(), iy = y.floor();
      if (ix % 8 == 0) {
        final tick = ix % 40 == 0 ? 9 : 5;
        if (y < tick || y >= 96 - tick) return true;
      }
      if (iy % 8 == 0) {
        final tick = iy % 40 == 0 ? 9 : 5;
        if (x < tick || x >= rows - tick) return true;
      }
    }
    // Disconnected glyph-like strokes at the same position as the real text.
    // Some glyphs are deliberately plus-shaped distractors.
    if (text && y >= 23 && y < 43 && x >= 12 && x < rows - 12) {
      final ix = (x - 12).floor(), iy = (y - 23).floor();
      if (iy % 11 < 7 && ix % 6 < 4) {
        return ix % 6 == 0 || iy % 11 == 0 || iy % 11 == 3;
      }
    }
    return false;
  }
}

Uint8List _blur(_Photo photo, int radius) {
  final width = photo.width, height = photo.height, size = radius * 2 + 1;
  final horizontal = Uint8List(width * height);
  final result = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    var sum = 0;
    for (var x = -radius; x <= radius; x++) {
      sum += photo.rgba[(y * width + x.clamp(0, width - 1).toInt()) * 4];
    }
    for (var x = 0; x < width; x++) {
      horizontal[y * width + x] = sum ~/ size;
      sum += photo
          .rgba[(y * width + (x + radius + 1).clamp(0, width - 1).toInt()) * 4];
      sum -= photo
          .rgba[(y * width + (x - radius).clamp(0, width - 1).toInt()) * 4];
    }
  }
  for (var x = 0; x < width; x++) {
    var sum = 0;
    for (var y = -radius; y <= radius; y++) {
      sum += horizontal[y.clamp(0, height - 1).toInt() * width + x];
    }
    for (var y = 0; y < height; y++) {
      final i = (y * width + x) * 4, value = sum ~/ size;
      result[i] = value;
      result[i + 1] = value;
      result[i + 2] = value;
      result[i + 3] = 255;
      sum +=
          horizontal[(y + radius + 1).clamp(0, height - 1).toInt() * width + x];
      sum -= horizontal[(y - radius).clamp(0, height - 1).toInt() * width + x];
    }
  }
  return result;
}

CalibrationPhotoPoint _project(List<double> m, double x, double y) {
  final z = m[6] * x + m[7] * y + m[8];
  return CalibrationPhotoPoint(
    (m[0] * x + m[1] * y + m[2]) / z,
    (m[3] * x + m[4] * y + m[5]) / z,
  );
}

List<double> _inverse(List<double> m) {
  final a = m[0], b = m[1], c = m[2];
  final d = m[3], e = m[4], f = m[5];
  final g = m[6], h = m[7], i = m[8];
  final det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  return [
    (e * i - f * h) / det,
    (c * h - b * i) / det,
    (b * f - c * e) / det,
    (f * g - d * i) / det,
    (a * i - c * g) / det,
    (c * d - a * f) / det,
    (d * h - e * g) / det,
    (b * g - a * h) / det,
    (a * e - b * d) / det,
  ];
}
