import 'dart:math' as math;
import 'dart:ui';

/// Physical dot scale, not a resampling instruction. The head is always 96 dots.
const mediaDotsPerMm = 8;
const printHeadDots = 96;
const maxMediaCanvasPixels = 16000000;

/// Raster origin expressed in physical paper coordinates. Positive offsets
/// leave the leading/top paper margin outside the head; negative offsets waste
/// raster dots before the paper starts. No implicit centering is performed.
class MediaProfile {
  MediaProfile({
    this.lengthMm = 30,
    this.widthMm = 12,
    this.radiusMm = 0,
    this.feedOffsetDots = 0,
    this.headOffsetDots = 0,
    this.name = 'Лента',
    this.measuredAt,
  }) {
    if (!lengthMm.isFinite ||
        lengthMm < 10 ||
        lengthMm > 150 ||
        !widthMm.isFinite ||
        widthMm < 1 ||
        widthMm > 150 ||
        !radiusMm.isFinite ||
        radiusMm < 0 ||
        radiusMm > math.min(lengthMm, widthMm) / 2 ||
        name.trim().isEmpty ||
        !feedOffsetDots.isFinite ||
        !headOffsetDots.isFinite) {
      throw ArgumentError(
        'Длина 10–150 мм, ширина 1–150 мм, радиус не больше половины короткой стороны; укажите название ленты.',
      );
    }
    if (printableRect.isEmpty || printablePath.getBounds().isEmpty) {
      throw ArgumentError('Бумага должна пересекаться с областью головки.');
    }
  }

  final double lengthMm, widthMm, radiusMm;
  final int feedOffsetDots, headOffsetDots;
  final String name;
  final DateTime? measuredAt;
  bool get isCalibrated => measuredAt != null;
  // The raster/cell encloses fractional physical edges; the paper paths retain
  // the exact dimensions. Rounding must never become a scale transform.
  double get lengthDots => lengthMm * mediaDotsPerMm;
  double get widthDots => widthMm * mediaDotsPerMm;
  int get rasterRows => lengthDots.ceil();
  int get paperHeightDots => widthDots.ceil();
  Rect get paperRect => Rect.fromLTWH(0, 0, lengthDots, widthDots);
  RRect get paperRRect => RRect.fromRectAndRadius(
    paperRect,
    Radius.circular(radiusMm * mediaDotsPerMm),
  );
  Path get paperPath => Path()..addRRect(paperRRect);
  Rect get headRect => Rect.fromLTWH(
    feedOffsetDots.toDouble(),
    headOffsetDots.toDouble(),
    rasterRows.toDouble(),
    printHeadDots.toDouble(),
  );
  Rect get printableRect => paperRect.intersect(headRect);
  Path get printablePath => Path.combine(
    PathOperation.intersect,
    paperPath,
    Path()..addRect(headRect),
  );

  /// Largest conservative integer-aligned safe rectangle. Its four corners
  /// lie inside the rounded paper, including every QR quiet-zone corner.
  Rect get safeRect {
    final inset = radiusMm * mediaDotsPerMm * (1 - math.sqrt(.5));
    final rect = Rect.fromLTRB(
      inset,
      inset,
      lengthDots - inset,
      widthDots - inset,
    ).intersect(headRect);
    final result = Rect.fromLTRB(
      rect.left.ceilToDouble(),
      rect.top.ceilToDouble(),
      rect.right.floorToDouble(),
      rect.bottom.floorToDouble(),
    );
    return result.isEmpty ? Rect.zero : result;
  }

  MediaProfile copyWith({
    double? lengthMm,
    double? widthMm,
    double? radiusMm,
    int? feedOffsetDots,
    int? headOffsetDots,
    String? name,
    DateTime? measuredAt,
    bool clearMeasurement = false,
  }) {
    final changed =
        (lengthMm != null && lengthMm != this.lengthMm) ||
        (widthMm != null && widthMm != this.widthMm) ||
        (radiusMm != null && radiusMm != this.radiusMm) ||
        (feedOffsetDots != null && feedOffsetDots != this.feedOffsetDots) ||
        (headOffsetDots != null && headOffsetDots != this.headOffsetDots);
    return MediaProfile(
      lengthMm: lengthMm ?? this.lengthMm,
      widthMm: widthMm ?? this.widthMm,
      radiusMm: radiusMm ?? this.radiusMm,
      feedOffsetDots: feedOffsetDots ?? this.feedOffsetDots,
      headOffsetDots: headOffsetDots ?? this.headOffsetDots,
      name: name ?? this.name,
      measuredAt: clearMeasurement
          ? null
          : (measuredAt ?? (changed ? null : this.measuredAt)),
    );
  }

  Map<String, dynamic> toJson() => {
    'lengthMm': lengthMm,
    'widthMm': widthMm,
    'radiusMm': radiusMm,
    'feedOffsetDots': feedOffsetDots,
    'headOffsetDots': headOffsetDots,
    'name': name,
    'measuredAt': measuredAt?.toUtc().toIso8601String(),
  };

  factory MediaProfile.fromJson(Map<String, dynamic> json) {
    try {
      return MediaProfile(
        lengthMm: (json['lengthMm'] as num).toDouble(),
        widthMm: (json['widthMm'] as num).toDouble(),
        radiusMm: (json['radiusMm'] as num).toDouble(),
        feedOffsetDots: json['feedOffsetDots'] as int,
        headOffsetDots: json['headOffsetDots'] as int,
        name: json['name'] as String,
        measuredAt: json['measuredAt'] == null
            ? null
            : DateTime.parse(json['measuredAt'] as String),
      );
    } catch (_) {
      throw const FormatException('Некорректный профиль физической ленты');
    }
  }
}
