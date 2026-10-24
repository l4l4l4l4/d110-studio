import 'dart:convert';
import 'dart:typed_data';

import 'package:d110_studio/calibration_photo_analysis.dart';
import 'package:d110_studio/media_calibration_session.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

MediaCalibrationSession review() => MediaCalibrationSession(
  step: MediaCalibrationStep.review,
  referenceRows: 240,
  referenceReady: true,
  draft: MediaProfile(
    lengthMm: 30.125,
    widthMm: 12.25,
    radiusMm: 1.375,
    feedOffsetDots: 3,
    headOffsetDots: -1,
  ),
  photo: Uint8List.fromList([1, 2, 3]),
  fiducials: const [
    CalibrationPhotoPoint(20, 20),
    CalibrationPhotoPoint(220, 20),
    CalibrationPhotoPoint(20, 60),
    CalibrationPhotoPoint(220, 60),
  ],
  paperOutline: const [
    CalibrationPhotoPoint(10, 10),
    CalibrationPhotoPoint(230, 10),
    CalibrationPhotoPoint(230, 90),
    CalibrationPhotoPoint(10, 90),
  ],
  edgeErrorDots: .3,
);

void main() {
  test('unknown reference outcome stays pending after process restoration', () {
    final pending = MediaCalibrationSession(
      pendingJob: CalibrationPrintJob.reference,
    );
    final restored = MediaCalibrationSession.decode(pending.encode());
    expect(restored.pendingJob, CalibrationPrintJob.reference);
    expect(restored.referenceReady, isFalse);
    expect(restored.verified, isFalse);
    expect(
      () => restored.copyWith(step: MediaCalibrationStep.photo),
      throwsFormatException,
    );
  });

  test(
    'verification cannot be accepted while its printer result is unknown',
    () {
      final pending = review().copyWith(
        step: MediaCalibrationStep.verification,
        pendingJob: CalibrationPrintJob.verification,
      );
      final restored = MediaCalibrationSession.decode(pending.encode());
      expect(
        () => restored.copyWith(
          step: MediaCalibrationStep.confirm,
          verified: true,
        ),
        throwsFormatException,
      );
      final completed = restored.copyWith(
        step: MediaCalibrationStep.confirm,
        verified: true,
        clearPendingJob: true,
      );
      expect(completed.verified, isTrue);
      expect(completed.draft!.measuredAt, isNull);
    },
  );

  test(
    'paper correction preserves the coordinate system of the printed reference',
    () {
      final restored = MediaCalibrationSession.decode(review().encode());
      final edited = restored.copyWith(
        draft: restored.draft!.copyWith(lengthMm: 40.375, radiusMm: 2.125),
      );
      final again = MediaCalibrationSession.decode(edited.encode());
      expect(again.referenceRows, 240);
      expect(again.draft!.lengthMm, 40.375);
      expect(again.draft!.radiusMm, 2.125);
      expect(again.draft!.widthMm, 12.25);
      expect(again.draft!.feedOffsetDots, 3);
      expect(again.draft!.headOffsetDots, -1);
      expect(again.draft!.measuredAt, isNull);
      expect(again.photo, orderedEquals([1, 2, 3]));
      expect(again.fiducials.last.x, 220);
    },
  );

  test(
    'corrupt progress is rejected rather than silently becoming a measured profile',
    () {
      final valid = jsonDecode(review().encode()) as Map<String, dynamic>;
      for (final patch in <Map<String, dynamic>>[
        {'schema': 2},
        {'step': 'confirm'},
        {'referenceReady': false},
        {'referenceRows': 79},
        {
          'fiducials': [
            [20, 20],
          ],
        },
        {'paperOutline': []},
        {'edgeErrorDots': -1},
        {'photo': 'not base64'},
        {
          'draft': {
            ...(valid['draft'] as Map<String, dynamic>),
            'measuredAt': '2026-01-01T00:00:00Z',
          },
        },
      ]) {
        expect(
          () =>
              MediaCalibrationSession.decode(jsonEncode({...valid, ...patch})),
          throwsFormatException,
        );
      }
    },
  );
}
