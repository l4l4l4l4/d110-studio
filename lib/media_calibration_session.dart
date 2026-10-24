import 'dart:convert';
import 'dart:typed_data';

import 'calibration_photo_analysis.dart';
import 'media_geometry.dart';

enum MediaCalibrationStep { reference, photo, review, verification, confirm }

enum CalibrationPrintJob { reference, verification }

/// A pending job is deliberately durable before sending anything to the printer.
/// Restoring it requires an explicit decision, never an automatic print retry.
class MediaCalibrationSession {
  MediaCalibrationSession({
    this.step = MediaCalibrationStep.reference,
    this.referenceRows = 80,
    this.referenceReady = false,
    this.pendingJob,
    this.draft,
    this.photo,
    this.fiducials = const [],
    this.paperOutline = const [],
    this.edgeErrorDots,
    this.verified = false,
    this.completed = false,
  }) {
    if (referenceRows < 80 ||
        referenceRows > 1200 ||
        (photo != null && (photo!.isEmpty || photo!.length > maxPhotoBytes)) ||
        (fiducials.isNotEmpty && fiducials.length != 4) ||
        paperOutline.length > 4096 ||
        (edgeErrorDots != null &&
            (!edgeErrorDots!.isFinite || edgeErrorDots! < 0)) ||
        (draft?.isCalibrated ?? false)) {
      throw const FormatException('Повреждён прогресс калибровки');
    }
    final needsMeasurement = step.index >= MediaCalibrationStep.review.index;
    if ((step != MediaCalibrationStep.reference && !referenceReady) ||
        (needsMeasurement &&
            (draft == null ||
                photo == null ||
                fiducials.length != 4 ||
                paperOutline.length < 4)) ||
        (verified &&
            (!referenceReady || draft == null || pendingJob != null)) ||
        (step == MediaCalibrationStep.confirm && !verified) ||
        (pendingJob == CalibrationPrintJob.reference &&
            step != MediaCalibrationStep.reference) ||
        (pendingJob == CalibrationPrintJob.verification &&
            step != MediaCalibrationStep.verification)) {
      throw const FormatException('Непоследовательный прогресс калибровки');
    }
    for (final point in [...fiducials, ...paperOutline]) {
      if (!point.x.isFinite ||
          !point.y.isFinite ||
          point.x.abs() > 100000 ||
          point.y.abs() > 100000) {
        throw const FormatException('Повреждены точки на снимке');
      }
    }
  }

  static const maxPhotoBytes = 16 * 1024 * 1024;
  final MediaCalibrationStep step;
  final int referenceRows;
  final bool referenceReady;
  final CalibrationPrintJob? pendingJob;
  final MediaProfile? draft;
  final Uint8List? photo;
  final List<CalibrationPhotoPoint> fiducials;
  final List<CalibrationPhotoPoint> paperOutline;
  final double? edgeErrorDots;
  final bool verified;
  final bool completed;

  MediaCalibrationSession copyWith({
    MediaCalibrationStep? step,
    bool? referenceReady,
    CalibrationPrintJob? pendingJob,
    bool clearPendingJob = false,
    MediaProfile? draft,
    Uint8List? photo,
    List<CalibrationPhotoPoint>? fiducials,
    List<CalibrationPhotoPoint>? paperOutline,
    double? edgeErrorDots,
    bool? verified,
    bool? completed,
  }) => MediaCalibrationSession(
    step: step ?? this.step,
    referenceRows: referenceRows,
    referenceReady: referenceReady ?? this.referenceReady,
    pendingJob: clearPendingJob ? null : (pendingJob ?? this.pendingJob),
    draft: draft ?? this.draft,
    photo: photo ?? this.photo,
    fiducials: fiducials ?? this.fiducials,
    paperOutline: paperOutline ?? this.paperOutline,
    edgeErrorDots: edgeErrorDots ?? this.edgeErrorDots,
    verified: verified ?? this.verified,
    completed: completed ?? this.completed,
  );

  String encode() => jsonEncode({
    'schema': 1,
    'step': step.name,
    'referenceRows': referenceRows,
    'referenceReady': referenceReady,
    'pendingJob': pendingJob?.name,
    'draft': draft?.toJson(),
    'photo': photo == null ? null : base64Encode(photo!),
    'fiducials': [
      for (final p in fiducials) [p.x, p.y],
    ],
    'paperOutline': [
      for (final p in paperOutline) [p.x, p.y],
    ],
    'edgeErrorDots': edgeErrorDots,
    'verified': verified,
    'completed': completed,
  });

  factory MediaCalibrationSession.decode(String text) {
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (json['schema'] != 1) throw const FormatException();
      List<CalibrationPhotoPoint> points(String key) {
        final list = json[key] as List;
        if (list.length > 4096) throw const FormatException();
        return [
          for (final pair in list)
            CalibrationPhotoPoint(
              ((pair as List)[0] as num).toDouble(),
              (pair[1] as num).toDouble(),
            ),
        ];
      }

      final encodedPhoto = json['photo'] as String?;
      if (encodedPhoto != null &&
          encodedPhoto.length > ((maxPhotoBytes + 2) ~/ 3) * 4) {
        throw const FormatException();
      }
      return MediaCalibrationSession(
        step: MediaCalibrationStep.values.byName(json['step'] as String),
        referenceRows: json['referenceRows'] as int,
        referenceReady: json['referenceReady'] as bool,
        pendingJob: json['pendingJob'] == null
            ? null
            : CalibrationPrintJob.values.byName(json['pendingJob'] as String),
        draft: json['draft'] == null
            ? null
            : MediaProfile.fromJson(json['draft'] as Map<String, dynamic>),
        photo: encodedPhoto == null ? null : base64Decode(encodedPhoto),
        fiducials: points('fiducials'),
        paperOutline: points('paperOutline'),
        edgeErrorDots: (json['edgeErrorDots'] as num?)?.toDouble(),
        verified: json['verified'] as bool,
        completed: json['completed'] as bool,
      );
    } catch (_) {
      throw const FormatException('Не удалось прочитать прогресс калибровки');
    }
  }
}
