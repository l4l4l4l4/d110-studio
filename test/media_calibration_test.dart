import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d110_studio/calibration_photo_analysis.dart';
import 'package:d110_studio/media_calibration.dart';
import 'package:d110_studio/media_calibration_session.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:d110_studio/raster.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Completer<void>? _entered;
Future<void> _operation = Future.value();

Future<T> track<T>(Future<T> Function() action) {
  final result = Future<T>.sync(action);
  _operation = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  if (_entered != null && !_entered!.isCompleted) _entered!.complete();
  return result;
}

Finder get primary => find.byKey(const ValueKey('calibration-primary'));

Future<void> until(WidgetTester tester, bool Function() ready) async {
  final elapsed = Stopwatch()..start();
  while (!ready() && elapsed.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue, reason: 'Controlled calibration I/O did not finish');
}

Future<void> settle(WidgetTester tester) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 20));
    final indicators = tester.widgetList<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        indicators.every((indicator) => indicator.value != null)) {
      await tester.pump(const Duration(milliseconds: 400));
      return;
    }
  }
  fail('Calibration did not finish its controlled asynchronous operation');
}

Future<void> open(
  WidgetTester tester, {
  required Future<void> Function(PrinterRaster) print,
  required Future<void> Function(MediaProfile) save,
  Future<Uint8List?> Function()? capture,
  Future<String?> Function()? readSession,
  Future<void> Function(String)? saveSession,
  ValueNotifier<bool>? link,
}) async {
  _entered = null;
  _operation = Future.value();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaCalibration(
              context,
              initial: MediaProfile(),
              printPattern: (raster) => track(() => print(raster)),
              saveProfile: (profile) => track(() => save(profile)),
              canPrint: link?.value ?? true,
              canPrintNow: link == null ? null : () => link.value,
              printerChanges: link,
              capturePhoto: capture == null ? null : () => track(capture),
              readSession: readSession,
              saveSession: saveSession,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await settle(tester);
}

Future<void> pressIO(WidgetTester tester) async {
  final button = tester.widget<FilledButton>(primary);
  _entered = Completer<void>();
  button.onPressed!();
  await until(tester, () => _entered!.isCompleted);
  var completed = false;
  unawaited(_operation.then((_) => completed = true));
  await until(tester, () => completed);
  _entered = null;
  await settle(tester);
}

Future<Uint8List> reviewPhoto(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xff202020), BlendMode.src);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(40, 30, 480, 192),
          const Radius.circular(32),
        ),
        Paint()..color = Colors.white,
      );
      for (final x in [81.0, 175.0]) {
        for (final y in [63.0, 143.0]) {
          canvas.drawRect(
            Rect.fromLTWH(x - 7, y - 1, 14, 2),
            Paint()..color = Colors.black,
          );
          canvas.drawRect(
            Rect.fromLTWH(x - 1, y - 7, 2, 14),
            Paint()..color = Colors.black,
          );
        }
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(640, 320);
      try {
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        image.dispose();
        picture.dispose();
      }
    }))!;

MediaCalibrationSession readyReview(Uint8List photo) => MediaCalibrationSession(
  step: MediaCalibrationStep.review,
  referenceReady: true,
  photo: photo,
  draft: MediaProfile(
    lengthMm: 30,
    widthMm: 12,
    radiusMm: 2,
    feedOffsetDots: 4,
  ),
  fiducials: const [
    CalibrationPhotoPoint(81, 63),
    CalibrationPhotoPoint(175, 63),
    CalibrationPhotoPoint(81, 143),
    CalibrationPhotoPoint(175, 143),
  ],
  paperOutline: const [
    CalibrationPhotoPoint(72, 30),
    CalibrationPhotoPoint(488, 30),
    CalibrationPhotoPoint(520, 62),
    CalibrationPhotoPoint(520, 190),
    CalibrationPhotoPoint(488, 222),
    CalibrationPhotoPoint(72, 222),
    CalibrationPhotoPoint(40, 190),
    CalibrationPhotoPoint(40, 62),
  ],
);

void main() {
  testWidgets(
    'reference ACK precedes camera and camera cancellation preserves the reference',
    (tester) async {
      final printed = <PrinterRaster>[];
      final pending = Completer<void>();
      String? progress;
      var captures = 0;
      await open(
        tester,
        print: (raster) async {
          printed.add(raster);
          await pending.future;
        },
        save: (_) async => fail('unverified profile saved'),
        capture: () async {
          captures++;
          return null;
        },
        saveSession: (json) async => progress = json,
      );
      final action = tester.widget<FilledButton>(primary).onPressed!;
      _entered = Completer<void>();
      action();
      action();
      await until(tester, () => _entered!.isCompleted);
      await tester.pump();
      expect(printed, hasLength(1));
      expect(captures, 0);
      expect(tester.widget<FilledButton>(primary).onPressed, isNull);
      expect(
        MediaCalibrationSession.decode(progress!).pendingJob,
        CalibrationPrintJob.reference,
      );
      pending.complete();
      await settle(tester);
      expect(MediaCalibrationSession.decode(progress!).referenceReady, isTrue);
      await pressIO(tester);
      expect(captures, 1);
      expect(printed, hasLength(1));
      final restored = MediaCalibrationSession.decode(progress!);
      expect(restored.step, MediaCalibrationStep.photo);
      expect(restored.referenceReady, isTrue);
      expect(restored.pendingJob, isNull);
      expect(tester.widget<FilledButton>(primary).onPressed, isNotNull);
    },
  );

  testWidgets(
    'uncertain print survives reopening and cannot auto-retry or save',
    (tester) async {
      var calls = 0;
      String? progress;
      Future<void> print(PrinterRaster _) async {
        calls++;
        throw StateError('ACK lost');
      }

      Future<void> save(MediaProfile _) async =>
          fail('unverified profile saved');
      await open(
        tester,
        print: print,
        save: save,
        saveSession: (json) async => progress = json,
      );
      await pressIO(tester);
      expect(calls, 1);
      expect(
        MediaCalibrationSession.decode(progress!).pendingJob,
        CalibrationPrintJob.reference,
      );
      await tester.pumpWidget(const SizedBox());
      await open(
        tester,
        print: print,
        save: save,
        readSession: () async => progress,
        saveSession: (json) async => progress = json,
      );
      expect(calls, 1);
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(MediaCalibrationSession.decode(progress!).verified, isFalse);
    },
  );

  testWidgets(
    'backgrounding during pending persistence cannot erase an uncertain print',
    (tester) async {
      String? progress;
      final persistence = Completer<void>();
      final ack = Completer<void>();
      var storingPending = false;
      var calls = 0;
      await open(
        tester,
        print: (_) async {
          calls++;
          await ack.future;
        },
        save: (_) async => fail('uncertain profile saved'),
        saveSession: (json) async {
          if (MediaCalibrationSession.decode(json).pendingJob != null) {
            storingPending = true;
            await persistence.future;
          }
          progress = json;
        },
      );
      tester.widget<FilledButton>(primary).onPressed!();
      await until(tester, () => storingPending);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      persistence.complete();
      await until(tester, () => calls == 1);
      ack.completeError(StateError('ACK lost'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(
        MediaCalibrationSession.decode(progress!).pendingJob,
        CalibrationPrintJob.reference,
      );
      await tester.pumpWidget(const SizedBox());
      await open(
        tester,
        print: (_) async => calls++,
        save: (_) async => fail('uncertain profile saved'),
        readSession: () async => progress,
        saveSession: (json) async => progress = json,
      );
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(find.text('Напечатать ещё один?'), findsOneWidget);
      expect(calls, 1);
      await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'uncertain verification keeps Back disabled and retains repeat consent',
    (tester) async {
      String? progress = readyReview(await reviewPhoto(tester))
          .copyWith(
            step: MediaCalibrationStep.verification,
            pendingJob: CalibrationPrintJob.verification,
          )
          .encode();
      var calls = 0;
      await open(
        tester,
        print: (_) async => calls++,
        save: (_) async => fail('uncertain profile saved'),
        readSession: () async => progress,
        saveSession: (json) async => progress = json,
      );
      final back = find.widgetWithIcon(IconButton, Icons.arrow_back);
      await tester.tap(back);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(tester.widget<IconButton>(back).onPressed, isNull);
      expect(
        MediaCalibrationSession.decode(progress!).pendingJob,
        CalibrationPrintJob.verification,
      );
      await tester.tap(primary);
      await tester.pumpAndSettle();
      expect(find.text('Напечатать ещё один?'), findsOneWidget);
      expect(calls, 0);
      await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'restored review needs an actual verification and save failure never reprints',
    (tester) async {
      String? progress = readyReview(await reviewPhoto(tester)).encode();
      final printed = <PrinterRaster>[];
      var good = MediaProfile(
        name: 'Previous good roll',
        measuredAt: DateTime.utc(2025),
      );
      var failSave = true;
      await open(
        tester,
        print: (raster) async => printed.add(raster),
        save: (profile) async {
          if (failSave) throw StateError('Disk unavailable');
          good = profile;
        },
        readSession: () async => progress,
        saveSession: (json) async => progress = json,
      );
      expect(printed, isEmpty);
      await tester.tap(primary);
      await settle(tester);
      expect(printed, isEmpty);
      expect(MediaCalibrationSession.decode(progress!).verified, isFalse);
      await pressIO(tester);
      expect(printed, hasLength(1));
      expect(MediaCalibrationSession.decode(progress!).verified, isTrue);
      await pressIO(tester);
      expect(good.name, 'Previous good roll');
      expect(printed, hasLength(1));
      failSave = false;
      await pressIO(tester);
      expect(printed, hasLength(1));
      expect(good.lengthMm, 30);
      expect(good.radiusMm, 2);
      expect(good.feedOffsetDots, 4);
      expect(good.measuredAt, isNotNull);
      expect(MediaCalibrationSession.decode(progress!).completed, isTrue);
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets(
    'a printer appearing while calibration is open enables but never starts printing',
    (tester) async {
      final link = ValueNotifier(false);
      addTearDown(link.dispose);
      var calls = 0;
      await open(
        tester,
        link: link,
        print: (_) async => calls++,
        save: (_) async => fail('offline profile saved'),
      );
      expect(tester.widget<FilledButton>(primary).onPressed, isNull);
      link.value = true;
      await tester.pump();
      expect(tester.widget<FilledButton>(primary).onPressed, isNotNull);
      expect(calls, 0);
      link.value = false;
      await tester.pump();
      expect(tester.widget<FilledButton>(primary).onPressed, isNull);
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'changing verified geometry requires a new verification but retains printed fiducial scale',
    (tester) async {
      String? progress = readyReview(
        await reviewPhoto(tester),
      ).copyWith(verified: true).encode();
      final printed = <PrinterRaster>[];
      await open(
        tester,
        print: (raster) async => printed.add(raster),
        save: (_) async => fail('saved before explicit visual confirmation'),
        readSession: () async => progress,
        saveSession: (json) async => progress = json,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Размеры'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('media-length')),
        '30.125',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Применить'));
      await settle(tester);
      var session = MediaCalibrationSession.decode(progress!);
      expect(session.verified, isFalse);
      expect(session.draft!.lengthMm, 30.125);
      expect(session.referenceRows, 80);
      expect(printed, isEmpty);
      await tester.tap(primary);
      await settle(tester);
      expect(
        MediaCalibrationSession.decode(progress!).step,
        MediaCalibrationStep.verification,
      );
      await pressIO(tester);
      expect(printed.single.height, 241);
      session = MediaCalibrationSession.decode(progress!);
      expect(session.referenceRows, 80);
      expect(session.step, MediaCalibrationStep.confirm);
      expect(session.draft!.measuredAt, isNull);
    },
  );

  testWidgets(
    'reference and verification keep dot scale and verification masks the whole rounded paper',
    (tester) async {
      await tester.runAsync(() async {
        final profile = MediaProfile(
          lengthMm: 30.125,
          widthMm: 14.5,
          radiusMm: 2,
          headOffsetDots: 10,
          feedOffsetDots: -2,
        );
        final reference = await renderMediaCalibrationPattern(profile);
        final verification = await renderMediaCalibrationPattern(
          profile,
          verification: true,
        );
        expect(reference.width, 96);
        expect(reference.height, 241);
        expect(verification.width, 96);
        expect(verification.height, 241);
        final paper = profile.paperPath;
        for (var feed = 0; feed < verification.height; feed++) {
          for (var head = 0; head < 96; head++) {
            if (!paper.contains(
              Offset(
                feed + .5 + profile.feedOffsetDots,
                head + .5 + profile.headOffsetDots,
              ),
            )) {
              expect(
                verification.rgba[(feed * 96 + 95 - head) * 4],
                255,
                reason: 'Ink outside paper at feed=$feed head=$head',
              );
            }
          }
        }
        final raster = await renderMediaCalibrationPattern(MediaProfile());
        expect(raster.rgba[(8 * 96 + 94) * 4], 0);
        expect(raster.rgba[(9 * 96 + 94) * 4], 255);
      });
    },
  );
}
