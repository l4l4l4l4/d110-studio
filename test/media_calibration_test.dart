import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:d110_studio/media_calibration.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:d110_studio/raster.dart';

Completer<void>? _entered;
Future<void> _operation = Future.value();

Future<void> track(Future<void> Function() action) {
  final result = Future<void>.sync(action);
  _operation = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  if (_entered != null && !_entered!.isCompleted) _entered!.complete();
  return result;
}

Future<void> open(
  WidgetTester tester, {
  required Future<void> Function(PrinterRaster) print,
  required Future<void> Function(MediaProfile) save,
  MediaProfile? initial,
  bool canPrint = true,
}) async {
  _entered = null;
  _operation = Future.value();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showMediaCalibration(
              context,
              initial: initial ?? MediaProfile(),
              printPattern: (raster) => track(() => print(raster)),
              saveProfile: (profile) => track(() => save(profile)),
              canPrint: canPrint,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String text) async {
  final button = tester.widget<TextButton>(
    find.widgetWithText(TextButton, text),
  );
  await tester.runAsync(() async {
    _entered = Completer<void>();
    button.onPressed!();
    await _entered!.future.timeout(const Duration(seconds: 10));
    await _operation;
    _entered = null;
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'measurement edits invalidate verification and save failure does not reprint',
    (tester) async {
      final printed = <PrinterRaster>[];
      final saved = <MediaProfile>[];
      var failSave = true;
      await open(
        tester,
        initial: MediaProfile(
          lengthMm: 30.25,
          widthMm: 14,
          radiusMm: 1.5,
          headOffsetDots: 4,
          measuredAt: DateTime.utc(2026),
        ),
        print: (raster) async => printed.add(raster),
        save: (profile) async {
          saved.add(profile);
          if (failSave) throw StateError('Disk unavailable');
        },
      );
      expect(printed, isEmpty);
      expect(find.text('30.25'), findsOneWidget);
      await press(tester, 'Печатать эталон');
      await press(tester, 'Печатать проверку');
      expect(printed, hasLength(2));
      await tester.enterText(
        find.byKey(const ValueKey('media-width')),
        '14.125',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile))
            .onChanged,
        isNull,
      );
      await press(tester, 'Печатать проверку');
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged!(
        true,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('media-name')),
        'Measured roll batch A',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Сохранить профиль'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved.single.widthMm, 14.125);
      expect(saved.single.name, 'Measured roll batch A');
      expect(saved.single.measuredAt, isNotNull);
      expect(find.textContaining('Disk unavailable'), findsOneWidget);
      failSave = false;
      await press(tester, 'Сохранить профиль');
      expect(printed, hasLength(3));
      expect(saved, hasLength(2));
      expect(find.text('Калибровка физической ленты'), findsNothing);
    },
  );

  testWidgets(
    'uncertain reference never auto-retries or enables a measured save',
    (tester) async {
      var calls = 0;
      late Completer<void> pending;
      late Completer<void> entered;
      await open(
        tester,
        print: (_) async {
          calls++;
          entered.complete();
          await pending.future;
        },
        save: (_) async => fail('unverified profile saved'),
      );
      final action = tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Печатать эталон'),
          )
          .onPressed!;
      await tester.runAsync(() async {
        pending = Completer<void>();
        entered = Completer<void>();
        action();
        action();
        await entered.future;
        expect(calls, 1);
        pending.completeError(StateError('ACK lost'));
        await _operation;
      });
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.textContaining('Автоповтора нет'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Сохранить профиль'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'paper preview stays visible while editing with the phone keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await open(
        tester,
        canPrint: false,
        print: (_) async => fail('printed offline'),
        save: (_) async => fail('saved without verification'),
      );
      void expectVisiblePreview() {
        final preview = tester.getRect(
          find.byKey(const ValueKey('media-profile-preview')),
        );
        expect(preview.top, greaterThanOrEqualTo(0));
        expect(preview.bottom, lessThanOrEqualTo(600));
        expect(preview.height, greaterThan(0));
      }

      expectVisiblePreview();
      for (final (key, value) in [('radius', '2.25'), ('head', '8')]) {
        final field = find.byKey(ValueKey('media-$key'));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.enterText(field, value);
        await tester.pumpAndSettle();
        expect(field.hitTestable(), findsOneWidget);
        expectVisiblePreview();
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preview-only calibration never invents measurements', (
    tester,
  ) async {
    await open(
      tester,
      canPrint: false,
      print: (_) async => fail('printed offline'),
      save: (_) async => fail('saved without verification'),
    );
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Печатать эталон'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Сохранить профиль'),
          )
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const ValueKey('media-feed')), '0.5');
    await tester.pumpAndSettle();
    expect(find.textContaining('целым'), findsOneWidget);
  });

  testWidgets(
    'reference and verification retain eight physical dots per millimetre',
    (tester) async {
      await tester.runAsync(() async {
        final profile = MediaProfile(
          lengthMm: 30.125,
          widthMm: 14.5,
          radiusMm: 2,
          headOffsetDots: 10,
          feedOffsetDots: -2,
        );
        for (final verify in [false, true]) {
          final raster = await renderMediaCalibrationPattern(
            profile,
            verification: verify,
          );
          expect(raster.width, 96);
          expect(raster.height, 241);
          expect(raster.packed.length, 241 * 12);
        }
        final raster = await renderMediaCalibrationPattern(MediaProfile());
        // Reference tick at unrotated (8, 1), rotated to (94, 8).
        expect(raster.rgba[(8 * 96 + 94) * 4], 0);
        expect(raster.rgba[(9 * 96 + 94) * 4], 255);
      });
    },
  );
}
