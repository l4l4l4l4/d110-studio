import 'dart:math' as math;
import 'dart:typed_data';

import 'media_calibration_pattern.dart';

/// Image coordinates use pixel edges: the first pixel's centre is (.5, .5).
class CalibrationPhotoPoint {
  const CalibrationPhotoPoint(this.x, this.y);
  final double x;
  final double y;
}

/// An optical measurement, not a physical verification of the printer.
class CalibrationPhotoAnalysis {
  CalibrationPhotoAnalysis({
    required this.lengthMm,
    required this.widthMm,
    required this.radiusMm,
    required this.feedOffsetDots,
    required this.headOffsetDots,
    required List<CalibrationPhotoPoint> fiducials,
    required List<CalibrationPhotoPoint> paperOutline,
    required this.edgeErrorDots,
  }) : fiducials = List.unmodifiable(fiducials),
       paperOutline = List.unmodifiable(paperOutline);

  final double lengthMm;
  final double widthMm;
  final double radiusMm;
  final int feedOffsetDots;
  final int headOffsetDots;
  final List<CalibrationPhotoPoint> fiducials;
  final List<CalibrationPhotoPoint> paperOutline;
  final double edgeErrorDots;
}

/// Measures the existing 7-by-7, one-dot crosses and the *whole* paper contour.
///
/// X is printer feed, Y is the 96-dot head. The known cross separations supply
/// scale; paper dimensions never supply scale. Corrected points must be in the
/// actual printed TL, TR, BL, BR order (not screen order). Automatic orientation
/// uses the existing ruler's asymmetric one-dot phase and 96-dot head extent.
/// Four crosses alone cannot determine orientation and are explicitly rejected.
///
/// Work is bounded to 1800-by-1800 RGBA, 18 candidate marks, 4-point linear solves
/// and 8192 contour samples. Pixel loops use typed buffers, not point objects.
/// This synchronous, engine-free API is suitable for a worker isolate.
CalibrationPhotoAnalysis analyzeCalibrationPhoto(
  Uint8List rgba,
  int width,
  int height, {
  required int referenceRows,
  List<CalibrationPhotoPoint>? fiducials,
}) {
  if (width < 64 ||
      height < 64 ||
      width > 1800 ||
      height > 1800 ||
      width * height > 3240000 ||
      rgba.length != width * height * 4) {
    _fail('Некорректное фото. Снимите ещё раз.');
  }
  if (referenceRows < 48 || referenceRows > 1200) {
    _fail('Сначала напечатайте эталон заново.');
  }
  final image = _PhotoPixels(rgba, width, height);
  final paper = image.findPaper();
  final rasterMarks = _rasterMarks(referenceRows);
  final chosen = fiducials == null
      ? _selectMarks(image, rasterMarks, referenceRows)
      : List<CalibrationPhotoPoint>.of(fiducials);
  final toImage = _checkedMarks(image, rasterMarks, chosen);
  final toDots = _Projective.fit(chosen, rasterMarks);

  // Reject projective poles or excessive extrapolation anywhere on the paper,
  // not just inside the four marks.
  final rectified = <CalibrationPhotoPoint>[];
  double? denominatorSign;
  for (final point in paper.hull) {
    final denominator = toDots.denominator(point.x, point.y);
    denominatorSign ??= denominator.sign;
    if (denominator.abs() < .08 || denominator.sign != denominatorSign) {
      _fail('Сильный наклон. Снимите бумагу сверху.');
    }
    final p = toDots.map(point.x, point.y);
    if (p.x.abs() > 2400 || p.y.abs() > 2400) {
      _fail('Сильный наклон. Снимите бумагу сверху.');
    }
    rectified.add(p);
  }
  final samples = _densify(rectified, .7);
  final fit = _RoundedPaper.fit(samples);
  if (fit.right - fit.left < 8 ||
      fit.bottom - fit.top < 8 ||
      fit.right - fit.left > 1200 ||
      fit.bottom - fit.top > 1200) {
    _fail('Размер вне диапазона. Снимите ближе и сверху.');
  }
  fit.checkCorners(samples);
  final worldOutline = fit.outline();
  _checkBoundary(image, worldOutline, toImage, referenceRows);
  final overlay = <CalibrationPhotoPoint>[
    for (final p in worldOutline) toImage.map(p.x, p.y),
  ];
  return CalibrationPhotoAnalysis(
    lengthMm: (fit.right - fit.left) / 8,
    widthMm: (fit.bottom - fit.top) / 8,
    radiusMm: fit.radius / 8,
    feedOffsetDots: (-fit.left).round(),
    headOffsetDots: (-fit.top).round(),
    fiducials: chosen,
    paperOutline: overlay,
    edgeErrorDots: fit.error,
  );
}

/// Projects an explicitly edited profile into the original photo. This does
/// not analyse pixels, certify an edit, or replace a rejected measurement.
List<CalibrationPhotoPoint> projectCalibrationPaperOutline({
  required int referenceRows,
  required List<CalibrationPhotoPoint> fiducials,
  required double lengthMm,
  required double widthMm,
  required double radiusMm,
  required int feedOffsetDots,
  required int headOffsetDots,
}) {
  if (referenceRows < 48 ||
      referenceRows > 1200 ||
      !lengthMm.isFinite ||
      !widthMm.isFinite ||
      !radiusMm.isFinite ||
      lengthMm <= 0 ||
      widthMm <= 0 ||
      lengthMm > 150 ||
      widthMm > 150 ||
      radiusMm < 0 ||
      radiusMm > math.min(lengthMm, widthMm) / 2) {
    _fail('Проверьте размеры и радиус бумаги.');
  }
  _validateQuad(fiducials);
  final map = _Projective.fit(_rasterMarks(referenceRows), fiducials);
  final left = -feedOffsetDots.toDouble(), top = -headOffsetDots.toDouble();
  final paper = _RoundedPaper(
    left,
    top,
    left + lengthMm * 8,
    top + widthMm * 8,
    radiusMm * 8,
    0,
  );
  final result = <CalibrationPhotoPoint>[];
  for (final p in paper.outline()) {
    if (map.denominator(p.x, p.y) < .08) {
      _fail('Контур вне плоскости фото. Проверьте размеры.');
    }
    result.add(map.map(p.x, p.y));
  }
  return List.unmodifiable(result);
}

List<CalibrationPhotoPoint> _rasterMarks(int rows) => [
  const CalibrationPhotoPoint(16.5, 16.5),
  CalibrationPhotoPoint(rows - 16.5, 16.5),
  const CalibrationPhotoPoint(16.5, 56.5),
  CalibrationPhotoPoint(rows - 16.5, 56.5),
];

Never _fail(String message) => throw FormatException(message);

double _cross(
  CalibrationPhotoPoint a,
  CalibrationPhotoPoint b,
  CalibrationPhotoPoint c,
) => (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

double _distance(CalibrationPhotoPoint a, CalibrationPhotoPoint b) =>
    math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

class _Paper {
  _Paper(this.hull);
  final List<CalibrationPhotoPoint> hull;
}

class _PhotoPixels {
  _PhotoPixels(Uint8List rgba, this.width, this.height)
    : gray = Uint8List(width * height),
      region = Uint8List(width * height),
      queue = Int32List(width * height) {
    final histogram = Int32List(256);
    var transparent = 0;
    for (var i = 0; i < gray.length; i++) {
      final k = i * 4;
      final value = (77 * rgba[k] + 150 * rgba[k + 1] + 29 * rgba[k + 2]) >> 8;
      gray[i] = value;
      histogram[value]++;
      if (rgba[k + 3] < 250) transparent++;
    }
    if (transparent > gray.length ~/ 100) {
      _fail('Нужно непрозрачное фото бумаги.');
    }
    int quantile(double fraction) {
      var count = 0;
      for (var i = 0; i < 256; i++) {
        count += histogram[i];
        if (count >= gray.length * fraction) return i;
      }
      return 255;
    }

    if (quantile(.99) - quantile(.01) < 65) {
      _fail('Мало контраста. Положите бумагу на тёмный фон.');
    }
    var sum = 0.0;
    for (var i = 0; i < 256; i++) {
      sum += i * histogram[i];
    }
    var lowCount = 0;
    var lowSum = 0.0;
    var bestVariance = -1.0;
    var split = 0;
    for (var i = 0; i < 255; i++) {
      lowCount += histogram[i];
      lowSum += i * histogram[i];
      final highCount = gray.length - lowCount;
      if (lowCount == 0 || highCount == 0) continue;
      final difference = lowSum / lowCount - (sum - lowSum) / highCount;
      final variance = lowCount * highCount * difference * difference;
      if (variance > bestVariance) {
        bestVariance = variance;
        split = i;
      }
    }
    lowCount = 0;
    lowSum = 0;
    for (var i = 0; i <= split; i++) {
      lowCount += histogram[i];
      lowSum += i * histogram[i];
    }
    if (lowCount == 0 || lowCount == gray.length) {
      _fail('Не видна бумага. Используйте тёмный фон.');
    }
    final dark = lowSum / lowCount;
    final light = (sum - lowSum) / (gray.length - lowCount);
    if (light - dark < 65) {
      _fail('Мало контраста. Используйте тёмный фон.');
    }
    // Otsu's split may lie anywhere in an empty histogram valley. Its two
    // cluster means give a stable subpixel edge threshold, unlike that split.
    threshold = (dark + light) / 2;
    for (var i = 0; i < gray.length; i++) {
      region[i] = gray[i] > threshold ? 1 : 0;
    }
  }

  final int width, height;
  final Uint8List gray;
  final Uint8List region;
  final Int32List queue;
  late final double threshold;
  late final Uint8List interior;

  int _flood(int seed, int from, int to, {bool diagonal = false}) {
    var used = 1;
    queue[0] = seed;
    region[seed] = to;
    for (var cursor = 0; cursor < used; cursor++) {
      final p = queue[cursor];
      final x = p % width, y = p ~/ width;
      for (var dy = -1; dy <= 1; dy++) {
        if (y + dy < 0 || y + dy >= height) continue;
        for (var dx = -1; dx <= 1; dx++) {
          if ((dx == 0 && dy == 0) ||
              (!diagonal && dx != 0 && dy != 0) ||
              x + dx < 0 ||
              x + dx >= width) {
            continue;
          }
          final q = p + dy * width + dx;
          if (region[q] == from) {
            region[q] = to;
            queue[used++] = q;
          }
        }
      }
    }
    return used;
  }

  _Paper findPaper() {
    var largest = 0, second = 0, seed = -1;
    for (var i = 0; i < region.length; i++) {
      if (region[i] != 1) continue;
      final count = _flood(i, 1, 2);
      if (count > largest) {
        second = largest;
        largest = count;
        seed = i;
      } else if (count > second) {
        second = count;
      }
    }
    if (largest < 2000 || largest < gray.length * .025 || seed < 0) {
      _fail('Бумага слишком мала. Снимите ближе.');
    }
    if (second > largest * .12) {
      _fail('Несколько светлых контуров. Оставьте один лист.');
    }
    final count = _flood(seed, 2, 3);
    final first = Int32List(height)..fillRange(0, height, width);
    final last = Int32List(height)..fillRange(0, height, -1);
    for (var i = 0; i < count; i++) {
      final p = queue[i], x = p % width, y = p ~/ width;
      if (x < 3 || y < 3 || x >= width - 3 || y >= height - 3) {
        _fail('Край обрезан. Снимите бумагу целиком.');
      }
      if (x < first[y]) first[y] = x;
      if (x > last[y]) last[y] = x;
    }
    // Only row extrema enter the convex hull. Ink holes, text and edge ruler
    // notches therefore cannot be mistaken for the outer paper boundary.
    final extremes = <CalibrationPhotoPoint>[];
    for (var y = 0; y < height; y++) {
      if (last[y] < 0) continue;
      final left = first[y].toDouble(), right = last[y] + 1.0;
      extremes.add(CalibrationPhotoPoint(left, y.toDouble()));
      extremes.add(CalibrationPhotoPoint(right, y.toDouble()));
      extremes.add(CalibrationPhotoPoint(left, y + 1.0));
      extremes.add(CalibrationPhotoPoint(right, y + 1.0));
    }
    final hull = _hull(extremes);
    var twiceArea = 0.0;
    for (var i = 0; i < hull.length; i++) {
      final a = hull[i], b = hull[(i + 1) % hull.length];
      twiceArea += a.x * b.y - a.y * b.x;
    }
    if (hull.length < 4 || largest / (twiceArea.abs() / 2) < .65) {
      _fail('Контур неясен. Уберите тени и посторонние предметы.');
    }
    interior = Uint8List(gray.length);
    for (var y = 0; y < height; y++) {
      final scanY = y + .5;
      var left = double.infinity, right = double.negativeInfinity;
      for (var j = 0; j < hull.length; j++) {
        final a = hull[j], b = hull[(j + 1) % hull.length];
        if ((a.y <= scanY && b.y > scanY) || (b.y <= scanY && a.y > scanY)) {
          final x = a.x + (scanY - a.y) * (b.x - a.x) / (b.y - a.y);
          left = math.min(left, x);
          right = math.max(right, x);
        }
      }
      if (!left.isFinite) continue;
      final start = math.max(0, (left - .5).ceil());
      final end = math.min(width, (right + .5).floor());
      if (end > start) {
        interior.fillRange(y * width + start, y * width + end, 1);
      }
    }
    return _Paper(hull);
  }

  bool inside(double x, double y) {
    if (!x.isFinite ||
        !y.isFinite ||
        x < 0 ||
        y < 0 ||
        x >= width ||
        y >= height) {
      return false;
    }
    return interior[y.floor() * width + x.floor()] != 0;
  }

  bool canSample(double x, double y) =>
      x.isFinite &&
      y.isFinite &&
      x >= .5 &&
      y >= .5 &&
      x < width - .5 &&
      y < height - .5;

  double sample(double x, double y) {
    if (!canSample(x, y)) {
      _fail('Край или крест вне кадра. Снимите целиком.');
    }
    x -= .5;
    y -= .5;
    final ix = x.floor(), iy = y.floor();
    final fx = x - ix, fy = y - iy, p = iy * width + ix;
    return (gray[p] * (1 - fx) + gray[p + 1] * fx) * (1 - fy) +
        (gray[p + width] * (1 - fx) + gray[p + width + 1] * fx) * fy;
  }

  List<_Mark> marks() {
    for (var i = 0; i < region.length; i++) {
      region[i] = interior[i] != 0 && gray[i] < threshold ? 1 : 0;
    }
    final found = <_Mark>[];
    for (var seed = 0; seed < region.length; seed++) {
      if (region[seed] != 1) continue;
      final count = _flood(seed, 1, 2, diagonal: true);
      if (count < 12 || count > 12000) continue;
      var sx = 0.0, sy = 0.0;
      for (var j = 0; j < count; j++) {
        sx += queue[j] % width + .5;
        sy += queue[j] ~/ width + .5;
      }
      final cx = sx / count, cy = sy / count;
      var xx = 0.0, yy = 0.0, xy = 0.0, radius2 = 0.0;
      var fourthReal = 0.0, fourthImag = 0.0, fourthTotal = 0.0;
      var thirdX = 0.0, thirdY = 0.0;
      for (var j = 0; j < count; j++) {
        final dx = queue[j] % width + .5 - cx;
        final dy = queue[j] ~/ width + .5 - cy;
        final x2 = dx * dx, y2 = dy * dy, r2 = x2 + y2;
        xx += x2;
        yy += y2;
        xy += dx * dy;
        radius2 = math.max(radius2, r2);
        fourthReal += x2 * x2 - 6 * x2 * y2 + y2 * y2;
        fourthImag += 4 * dx * dy * (x2 - y2);
        fourthTotal += r2 * r2;
        thirdX += dx * r2;
        thirdY += dy * r2;
      }
      final trace = xx + yy;
      final spread = math.sqrt((xx - yy) * (xx - yy) + 4 * xy * xy);
      final minor = (trace - spread) / 2;
      if (minor <= 0 || (trace + spread) / (2 * minor) > 5 || radius2 < 8) {
        continue;
      }
      final harmonic =
          math.sqrt(fourthReal * fourthReal + fourthImag * fourthImag) /
          math.max(1, fourthTotal);
      final skew =
          math.sqrt(thirdX * thirdX + thirdY * thirdY) /
          (count * math.pow(radius2, 1.5));
      final fill = count / (math.pi * radius2);
      if (harmonic < .28 || skew > .16 || fill < .12 || fill > .63) continue;
      // Crosses have central symmetry; letters such as E/F and L-shaped ruler
      // corners can have a similar fourth moment but fail this image test.
      var mirrored = 0;
      for (var j = 0; j < count; j++) {
        final mx = 2 * cx - (queue[j] % width + .5);
        final my = 2 * cy - (queue[j] ~/ width + .5);
        if (mx < .5 || my < .5 || mx >= width - .5 || my >= height - .5) {
          continue;
        }
        if (sample(mx, my) < threshold) mirrored++;
      }
      if (mirrored < count * .65) continue;
      found.add(_Mark(CalibrationPhotoPoint(cx, cy), harmonic - skew));
      if (found.length > 18) {
        _fail('Много похожих меток. Укажите четыре креста вручную.');
      }
    }
    return found;
  }
}

class _Mark {
  _Mark(this.point, this.score);
  final CalibrationPhotoPoint point;
  final double score;
}

List<CalibrationPhotoPoint> _hull(List<CalibrationPhotoPoint> points) {
  points.sort((a, b) {
    final x = a.x.compareTo(b.x);
    return x == 0 ? a.y.compareTo(b.y) : x;
  });
  final lower = <CalibrationPhotoPoint>[], upper = <CalibrationPhotoPoint>[];
  for (final p in points) {
    while (lower.length >= 2 &&
        _cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  for (final p in points.reversed) {
    while (upper.length >= 2 &&
        _cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  return [...lower.take(lower.length - 1), ...upper.take(upper.length - 1)];
}

List<CalibrationPhotoPoint> _selectMarks(
  _PhotoPixels image,
  List<CalibrationPhotoPoint> raster,
  int rows,
) {
  final marks = image.marks()..sort((a, b) => b.score.compareTo(a.score));
  if (marks.length < 4) {
    _fail('Не видны четыре креста. Снимите ближе и резче.');
  }
  List<CalibrationPhotoPoint>? best;
  var bestScore = -2.0, secondScore = -2.0;
  var recognizable = false;
  for (var a = 0; a < marks.length - 3; a++) {
    for (var b = a + 1; b < marks.length - 2; b++) {
      for (var c = b + 1; c < marks.length - 1; c++) {
        for (var d = c + 1; d < marks.length; d++) {
          final corners = [
            marks[a].point,
            marks[b].point,
            marks[c].point,
            marks[d].point,
          ];
          final cx = corners.fold<double>(0, (sum, p) => sum + p.x) / 4;
          final cy = corners.fold<double>(0, (sum, p) => sum + p.y) / 4;
          corners.sort(
            (p, q) => math
                .atan2(p.y - cy, p.x - cx)
                .compareTo(math.atan2(q.y - cy, q.x - cx)),
          );
          for (var start = 0; start < 4; start++) {
            for (final direction in [-1, 1]) {
              final ordered = [
                corners[start],
                corners[(start + direction) % 4],
                corners[(start - direction) % 4],
                corners[(start + 2) % 4],
              ];
              try {
                final transform = _checkedMarks(image, raster, ordered);
                recognizable = true;
                final score = _rulerScore(image, transform, rows);
                if (score > bestScore) {
                  secondScore = bestScore;
                  bestScore = score;
                  best = ordered;
                } else if (score > secondScore) {
                  secondScore = score;
                }
              } on FormatException {
                // A rejected hypothesis is not a measurement or a fallback.
              }
            }
          }
        }
      }
    }
  }
  if (!recognizable) {
    _fail('Кресты неразборчивы. Снимите ближе и сверху.');
  }
  if (best == null || bestScore < .52 || bestScore - secondScore < .12) {
    _fail('Неясен порядок крестов. Укажите четыре креста вручную.');
  }
  return best;
}

void _validateQuad(List<CalibrationPhotoPoint> points) {
  if (points.length != 4) _fail('Укажите четыре креста по порядку.');
  for (final p in points) {
    if (!p.x.isFinite || !p.y.isFinite) {
      _fail('Некорректные координаты крестов.');
    }
  }
  final polygon = [points[0], points[1], points[3], points[2]];
  var sign = 0.0, area = 0.0;
  for (var i = 0; i < 4; i++) {
    final a = polygon[i], b = polygon[(i + 1) % 4], c = polygon[(i + 2) % 4];
    final turn = _cross(a, b, c);
    if (turn.abs() < 16 || (sign != 0 && turn.sign != sign)) {
      _fail('Неверный порядок крестов. Уточните точки.');
    }
    sign = turn.sign;
    area += a.x * b.y - a.y * b.x;
  }
  if (area.abs() < 400) _fail('Кресты слишком близко. Снимите ближе.');
}

_Projective _checkedMarks(
  _PhotoPixels image,
  List<CalibrationPhotoPoint> raster,
  List<CalibrationPhotoPoint> points,
) {
  if (points.length != 4) _fail('Укажите четыре креста по порядку.');
  for (final p in points) {
    if (!image.inside(p.x, p.y)) _fail('Крест вне бумаги. Уточните точки.');
  }
  _validateQuad(points);
  final map = _Projective.fit(raster, points);
  final side = (calibrationMarkerArm + 1) * 2 + 1;
  final values = Float64List(side * side);
  for (final p in raster) {
    final centre = map.map(p.x, p.y);
    final right = map.map(p.x + 1, p.y);
    final down = map.map(p.x, p.y + 1);
    final a = right.x - centre.x, b = down.x - centre.x;
    final c = right.y - centre.y, d = down.y - centre.y;
    final trace = a * a + b * b + c * c + d * d;
    final determinant = a * d - b * c;
    final discriminant = math.sqrt(
      math.max(0, trace * trace - 4 * determinant * determinant),
    );
    final minimum = math.sqrt(math.max(0, (trace - discriminant) / 2));
    final maximum = math.sqrt((trace + discriminant) / 2);
    if (minimum < 1.6 || maximum / minimum > 3.5 || maximum > 50) {
      _fail('Мало деталей или сильный наклон. Снимите ближе и сверху.');
    }
    if (!_matchesMarker(image, map, p, values) &&
        // Previously printed references remain usable after session recovery.
        !_matchesMarker(image, map, p, values, arm: 3, halfStroke: 0)) {
      _fail('Кресты неразборчивы. Уточните центры, резкость и свет.');
    }
  }
  return map;
}

bool _matchesMarker(
  _PhotoPixels image,
  _Projective map,
  CalibrationPhotoPoint point,
  Float64List values, {
  int arm = calibrationMarkerArm,
  int halfStroke = calibrationMarkerHalfStroke,
}) {
  final radius = arm + 1;
  var black = 0.0, white = 0.0;
  var nBlack = 0, nWhite = 0, k = 0;
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      final value = map.sample(image, point.x + dx, point.y + dy);
      values[k++] = value;
      if (calibrationMarkerInk(dx, dy, arm: arm, halfStroke: halfStroke)) {
        black += value;
        nBlack++;
      } else {
        white += value;
        nWhite++;
      }
    }
  }
  black /= nBlack;
  white /= nWhite;
  if (white - black < 75 || white < image.threshold + 20) return false;
  final middle = (white + black) / 2;
  var missing = 0, unwanted = 0;
  k = 0;
  for (var dy = -radius; dy <= radius; dy++) {
    for (var dx = -radius; dx <= radius; dx++) {
      final value = values[k++];
      final ink = calibrationMarkerInk(
        dx,
        dy,
        arm: arm,
        halfStroke: halfStroke,
      );
      if (ink && value > middle) missing++;
      if (!ink && value < middle) unwanted++;
    }
  }
  return missing <= math.max(2, nBlack * .08) &&
      unwanted <= math.max(5, nWhite * .04);
}

double _rulerScore(_PhotoPixels image, _Projective map, int rows) {
  var count = 0, good = 0;
  var score = 0.0;
  void pair(double x, double y, double dx, double dy) {
    final black = map.map(x, y), white = map.map(x + dx, y + dy);
    if (!image.inside(black.x, black.y) || !image.inside(white.x, white.y)) {
      return;
    }
    final b = image.sample(black.x, black.y),
        w = image.sample(white.x, white.y);
    final difference = w - b;
    count++;
    score += (difference / 180).clamp(-1.0, 1.0);
    if (difference > 70 && w > image.threshold + 15) good++;
  }

  // These are physical pixel centres from renderMediaCalibrationPattern.
  // In particular X=.5+8n is NOT invariant under X -> referenceRows-X.
  for (var x = 8; x < rows - 8; x += 8) {
    pair(x + .5, 2.5, 2, 0);
    pair(x + .5, 93.5, 2, 0);
  }
  for (var y = 8; y < 88; y += 8) {
    pair(2.5, y + .5, 0, 2);
    pair(rows - 2.5, y + .5, 0, 2);
  }
  if (count < 12 || good < count * .6) return -1;
  return score / count;
}

/// A normalized eight-unknown solve; no iterative, unbounded RANSAC or external
/// numerical library is needed for the four selected fiducials.
class _Projective {
  _Projective(this.h, this.sx, this.sy, this.ss, this.tx, this.ty, this.ts);
  final Float64List h;
  final double sx, sy, ss, tx, ty, ts;

  static _Projective fit(
    List<CalibrationPhotoPoint> source,
    List<CalibrationPhotoPoint> target,
  ) {
    final sx = source.fold<double>(0, (s, p) => s + p.x) / 4;
    final sy = source.fold<double>(0, (s, p) => s + p.y) / 4;
    final tx = target.fold<double>(0, (s, p) => s + p.x) / 4;
    final ty = target.fold<double>(0, (s, p) => s + p.y) / 4;
    var ss = 0.0, ts = 0.0;
    for (var i = 0; i < 4; i++) {
      ss += math.sqrt(
        math.pow(source[i].x - sx, 2) + math.pow(source[i].y - sy, 2),
      );
      ts += math.sqrt(
        math.pow(target[i].x - tx, 2) + math.pow(target[i].y - ty, 2),
      );
    }
    ss /= 4;
    ts /= 4;
    if (ss < 1 || ts < 1) _fail('Кресты совпадают. Уточните точки.');
    final matrix = List.generate(8, (_) => Float64List(9));
    for (var i = 0; i < 4; i++) {
      final x = (source[i].x - sx) / ss, y = (source[i].y - sy) / ss;
      final u = (target[i].x - tx) / ts, v = (target[i].y - ty) / ts;
      final a = matrix[2 * i], b = matrix[2 * i + 1];
      a[0] = x;
      a[1] = y;
      a[2] = 1;
      a[6] = -u * x;
      a[7] = -u * y;
      a[8] = u;
      b[3] = x;
      b[4] = y;
      b[5] = 1;
      b[6] = -v * x;
      b[7] = -v * y;
      b[8] = v;
    }
    for (var column = 0; column < 8; column++) {
      var pivot = column;
      for (var row = column + 1; row < 8; row++) {
        if (matrix[row][column].abs() > matrix[pivot][column].abs()) {
          pivot = row;
        }
      }
      if (matrix[pivot][column].abs() < 1e-8) {
        _fail('Геометрия крестов вырождена. Снимите сверху.');
      }
      final swap = matrix[column];
      matrix[column] = matrix[pivot];
      matrix[pivot] = swap;
      final value = matrix[column][column];
      for (var k = column; k < 9; k++) {
        matrix[column][k] /= value;
      }
      for (var row = 0; row < 8; row++) {
        if (row == column) continue;
        final factor = matrix[row][column];
        for (var k = column; k < 9; k++) {
          matrix[row][k] -= factor * matrix[column][k];
        }
      }
    }
    final h = Float64List(8);
    for (var i = 0; i < 8; i++) {
      h[i] = matrix[i][8];
    }
    return _Projective(h, sx, sy, ss, tx, ty, ts);
  }

  double denominator(double x, double y) =>
      h[6] * ((x - sx) / ss) + h[7] * ((y - sy) / ss) + 1;

  // The dense stencil path avoids allocating a point for each sampled pixel.
  double sample(_PhotoPixels image, double x, double y) {
    x = (x - sx) / ss;
    y = (y - sy) / ss;
    final z = h[6] * x + h[7] * y + 1;
    if (z.abs() < 1e-8) _fail('Сильный наклон. Снимите сверху.');
    return image.sample(
      (h[0] * x + h[1] * y + h[2]) / z * ts + tx,
      (h[3] * x + h[4] * y + h[5]) / z * ts + ty,
    );
  }

  CalibrationPhotoPoint map(double x, double y) {
    x = (x - sx) / ss;
    y = (y - sy) / ss;
    final z = h[6] * x + h[7] * y + 1;
    if (z.abs() < 1e-8) _fail('Сильный наклон. Снимите сверху.');
    final u = (h[0] * x + h[1] * y + h[2]) / z * ts + tx;
    final v = (h[3] * x + h[4] * y + h[5]) / z * ts + ty;
    if (!u.isFinite || !v.isFinite) _fail('Не удалось восстановить геометрию.');
    return CalibrationPhotoPoint(u, v);
  }
}

List<CalibrationPhotoPoint> _densify(
  List<CalibrationPhotoPoint> polygon,
  double step,
) {
  final points = <CalibrationPhotoPoint>[];
  for (var i = 0; i < polygon.length; i++) {
    final a = polygon[i], b = polygon[(i + 1) % polygon.length];
    final count = math.max(1, (_distance(a, b) / step).ceil());
    if (points.length + count > 8192) {
      _fail('Контур слишком сложен. Снимите ближе и сверху.');
    }
    for (var j = 0; j < count; j++) {
      points.add(
        CalibrationPhotoPoint(
          a.x + (b.x - a.x) * j / count,
          a.y + (b.y - a.y) * j / count,
        ),
      );
    }
  }
  return points;
}

class _RoundedPaper {
  _RoundedPaper(
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.radius,
    this.error,
  );
  final double left, top, right, bottom, radius, error;

  static double _signedDistance(double x, double y, List<double> p) {
    final qx = (x - (p[0] + p[2]) / 2).abs() - (p[2] - p[0]) / 2 + p[4];
    final qy = (y - (p[1] + p[3]) / 2).abs() - (p[3] - p[1]) / 2 + p[4];
    final ox = math.max(qx, 0.0), oy = math.max(qy, 0.0);
    return math.sqrt(ox * ox + oy * oy) + math.min(math.max(qx, qy), 0) - p[4];
  }

  static _RoundedPaper fit(List<CalibrationPhotoPoint> points) {
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    for (final p in points) {
      left = math.min(left, p.x);
      right = math.max(right, p.x);
      top = math.min(top, p.y);
      bottom = math.max(bottom, p.y);
    }
    final short = math.min(right - left, bottom - top);
    if (short < 8 || short > 1600) {
      _fail('Неясный масштаб бумаги. Снимите сверху.');
    }
    final parameters = [left, top, right, bottom, 0.0];
    double cost(List<double> p) {
      if (p[2] <= p[0] ||
          p[3] <= p[1] ||
          p[4] < 0 ||
          p[4] > math.min(p[2] - p[0], p[3] - p[1]) / 2) {
        return double.infinity;
      }
      var sum = 0.0;
      for (final point in points) {
        final d = _signedDistance(point.x, point.y, p);
        sum += d * d;
      }
      return sum / points.length;
    }

    var best = cost(parameters), bestRadius = 0.0;
    for (var i = 1; i <= 40; i++) {
      parameters[4] = short * i / 80;
      final value = cost(parameters);
      if (value < best) {
        best = value;
        bestRadius = parameters[4];
      }
    }
    parameters[4] = bestRadius;
    var step = math.max(.5, short / 24);
    for (var scale = 0; scale < 11; scale++, step /= 2) {
      for (var sweep = 0; sweep < 8; sweep++) {
        var improved = false;
        for (var axis = 0; axis < 5; axis++) {
          final old = parameters[axis];
          var chosen = old;
          for (final direction in [-1, 1]) {
            parameters[axis] = old + direction * step;
            final value = cost(parameters);
            if (value < best) {
              best = value;
              chosen = parameters[axis];
              improved = true;
            }
          }
          parameters[axis] = chosen;
        }
        if (!improved) break;
      }
    }
    var maximum = 0.0;
    for (final point in points) {
      maximum = math.max(
        maximum,
        _signedDistance(point.x, point.y, parameters).abs(),
      );
    }
    final error = math.sqrt(best);
    if (error > .65 || maximum > 1.8) {
      _fail('Контур не совпадает. Расправьте бумагу и снимите сверху.');
    }
    return _RoundedPaper(
      parameters[0],
      parameters[1],
      parameters[2],
      parameters[3],
      parameters[4],
      error,
    );
  }

  void checkCorners(List<CalibrationPhotoPoint> samples) {
    for (var side = 0; side < 4; side++) {
      final isLeft = side == 0 || side == 3;
      final isTop = side < 2;
      final x = isLeft ? left : right, y = isTop ? top : bottom;
      if (radius <= 1.5) {
        var distance = double.infinity;
        for (final p in samples) {
          distance = math.min(
            distance,
            math.sqrt((p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)),
          );
        }
        if (distance > 1.9) _fail('Не видны все углы бумаги. Снимите целиком.');
        continue;
      }
      final cx = x + (isLeft ? radius : -radius);
      final cy = y + (isTop ? radius : -radius);
      var count = 0, sum = 0.0, minAngle = double.infinity, maxAngle = 0.0;
      for (final p in samples) {
        final dx = (p.x - cx) * (isLeft ? -1 : 1);
        final dy = (p.y - cy) * (isTop ? -1 : 1);
        if (dx < radius * .15 || dy < radius * .15) continue;
        final d = math.sqrt(dx * dx + dy * dy) - radius;
        sum += d * d;
        count++;
        final angle = math.atan2(dy, dx);
        minAngle = math.min(minAngle, angle);
        maxAngle = math.max(maxAngle, angle);
      }
      if (count < 2 ||
          maxAngle - minAngle < .35 ||
          math.sqrt(sum / count) > .9) {
        _fail('Радиус углов неясен. Снимите все четыре угла резче.');
      }
    }
  }

  List<CalibrationPhotoPoint> outline() {
    final points = <CalibrationPhotoPoint>[];
    final centres = [
      CalibrationPhotoPoint(left + radius, top + radius),
      CalibrationPhotoPoint(right - radius, top + radius),
      CalibrationPhotoPoint(right - radius, bottom - radius),
      CalibrationPhotoPoint(left + radius, bottom - radius),
    ];
    final starts = [math.pi, math.pi * 1.5, 0.0, math.pi / 2];
    final steps = math.max(2, (radius * math.pi / 2).ceil());
    for (var corner = 0; corner < 4; corner++) {
      for (var i = 0; i <= steps; i++) {
        final angle = starts[corner] + math.pi / 2 * i / steps;
        points.add(
          CalibrationPhotoPoint(
            centres[corner].x + radius * math.cos(angle),
            centres[corner].y + radius * math.sin(angle),
          ),
        );
      }
    }
    return _densify(points, 1.5);
  }
}

void _checkBoundary(
  _PhotoPixels image,
  List<CalibrationPhotoPoint> outline,
  _Projective map,
  int rows,
) {
  var checked = 0, contrast = 0, badInside = 0, badOutside = 0;
  var run = 0.0, leadingRun = 0.0, longestRun = 0.0;
  var leading = true;
  for (var i = 0; i < outline.length; i++) {
    final p = outline[i];
    final a = outline[(i + outline.length - 1) % outline.length];
    final b = outline[(i + 1) % outline.length];
    final dx = b.x - a.x, dy = b.y - a.y;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length < .001) continue;
    final nx = dy / length, ny = -dx / length;
    final edge = map.map(p.x, p.y);
    if (edge.x < 3 ||
        edge.y < 3 ||
        edge.x > image.width - 3 ||
        edge.y > image.height - 3) {
      _fail('Край обрезан. Снимите бумагу целиком.');
    }
    final ix = p.x - nx * 2, iy = p.y - ny * 2;
    final inside = map.map(ix, iy),
        outside = map.map(p.x + nx * 2, p.y + ny * 2);
    if (!image.canSample(inside.x, inside.y) ||
        !image.canSample(outside.x, outside.y)) {
      _fail('Оставьте тёмный отступ вокруг бумаги.');
    }
    final light = image.sample(inside.x, inside.y),
        dark = image.sample(outside.x, outside.y);
    checked++;
    final outsideBad = dark > image.threshold;
    final insideBad = light < image.threshold && !_printedAt(ix, iy, rows);
    if (outsideBad) badOutside++;
    if (insideBad) badInside++;
    if (light >= image.threshold && light - dark > 65) contrast++;
    if (insideBad || outsideBad) {
      run += _distance(a, p);
      if (leading) leadingRun = run;
      longestRun = math.max(longestRun, run);
    } else {
      leading = false;
      run = 0;
    }
  }
  // The hull alone would conceal a torn/concave edge. Real inside/outside
  // photometry must also support the fitted contour. Known edge ticks may be
  // dark inside; arbitrary dark gaps may not.
  longestRun = math.max(longestRun, run + leadingRun);
  if (checked < 24 ||
      contrast < checked * .65 ||
      longestRun > 4.5 ||
      badInside > checked * .06 ||
      badOutside > checked * .06) {
    _fail('Край неясен. Уберите тени и снимите бумагу целиком.');
  }
}

bool _printedAt(double x, double y, int rows) {
  if (x < 0 || x >= rows || y < 0 || y >= 96) return false;
  final ix = x.floor(), iy = y.floor();
  if (ix % 8 == 0) {
    final tick = ix % 40 == 0 ? 9 : 5;
    if (y < tick || y >= 96 - tick) return true;
  }
  if (iy % 8 == 0) {
    final tick = iy % 40 == 0 ? 9 : 5;
    if (x < tick || x >= rows - tick) return true;
  }
  if (x >= 12 && x <= rows - 12 && y >= 22 && y <= 45) return true;
  for (var column = 0; column < 2; column++) {
    final cx = column == 0 ? 16.5 : rows - 16.5;
    for (var row = 0; row < 2; row++) {
      final cy = row == 0 ? 16.5 : 56.5;
      if (((x - cx).abs() <= .65 && (y - cy).abs() <= 3.7) ||
          ((x - cx).abs() <= 3.7 && (y - cy).abs() <= .65)) {
        return true;
      }
    }
  }
  return false;
}
