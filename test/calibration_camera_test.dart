import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:camera_platform_interface/src/method_channel/method_channel_camera.dart';
import 'package:d110_studio/calibration_camera.dart';
import 'package:d110_studio/media_calibration.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<List<int>> _imagePixels(ui.Image image) async {
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return data!.buffer.asUint8List().toList();
}

void main() {
  late _CameraHost camera;
  late CameraPlatform previousPlatform;

  setUp(() {
    camera = _CameraHost();
    previousPlatform = CameraPlatform.instance;
    CameraPlatform.instance = _StreamingMethodChannelCamera();
    camera.install();
  });

  tearDown(() async {
    camera.uninstall();
    await camera.removeFiles();
    CameraPlatform.instance = previousPlatform;
  });

  void cameraTestWidgets(
    String description,
    WidgetTesterCallback body, {
    TargetPlatform platform = TargetPlatform.android,
  }) {
    testWidgets(description, (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      try {
        await body(tester);
      } finally {
        // Dispose the route before releasing any blocked native replies, even
        // when an expectation failed. No camera future outlives its fixture.
        await tester.pumpWidget(const SizedBox.shrink());
        camera.completePendingRequests();
        await tester.pump();
        await waitForCameraIo(
          tester,
          () => camera.ids.every(camera.disposed.contains),
        );
      }
    }, variant: TargetPlatformVariant({platform}));
  }

  cameraTestWidgets('reference print enters real camera and Back can reprint', (
    tester,
  ) async {
    var prints = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showMediaCalibration(
                context,
                initial: MediaProfile(),
                canPrint: true,
                printPattern: (_) async => prints++,
                saveProfile: (_) async => fail('unverified profile saved'),
              ),
              child: const Text('Calibrate'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Calibrate'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('calibration-primary')));
    await waitForCameraIo(tester, () => camera.ids.length == 1);
    expect(prints, 1);
    expect(find.byType(CameraPreview), findsOneWidget);
    expect(camera.captures, 0);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('calibration-reprint-reference')),
    );
    await waitForCameraIo(tester, () => camera.ids.length == 2);
    expect(prints, 2);
    expect(find.byType(CameraPreview), findsOneWidget);
    expect(camera.captures, 0);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
  });

  cameraTestWidgets(
    'back-camera preview waits for one explicit still-photo shutter',
    (tester) async {
      final result = await _openCapture(tester);

      expect(find.byType(CameraPreview), findsOneWidget);
      expect(camera.captures, 0);
      final previewAspect = tester.widget<AspectRatio>(
        find.descendant(
          of: find.byType(CameraPreview),
          matching: find.byType(AspectRatio),
        ),
      );
      expect(previewAspect.aspectRatio, closeTo(0.75, 0.001));

      final path = (await tester.runAsync(camera.makePhoto))!;
      camera.pictureGate = Completer<String>();
      await tester.tap(find.text('Снять'));
      await tester.pump();
      await tester.tap(find.text('Снять'));
      await tester.pump();
      await waitForCameraIo(tester, () => camera.captures == 1);
      expect(camera.captures, 1);

      // Complete native/controller futures in their original fake-async zone.
      // Only the OS file read needs real event-loop turns between widget pumps.
      camera.pictureGate!.complete(path);
      final readDeadline = Stopwatch()..start();
      while (!result.isCompleted &&
          readDeadline.elapsed < const Duration(seconds: 5)) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(
        result.isCompleted,
        isTrue,
        reason: 'The explicit photo must finish reading and close its route.',
      );
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), orderedEquals(_photoBytes));
      expect(camera.disposed, contains(camera.ids.single));
      expect(await tester.runAsync(() => File(path).exists()), isFalse);
    },
  );

  cameraTestWidgets(
    'unsupported desktop never opens a camera and can import',
    (tester) async {
      final picked = Completer<Uint8List?>();
      var imports = 0;
      final result = await _openCapture(
        tester,
        pickImage: () {
          imports++;
          return picked.future;
        },
      );
      expect(camera.enumerations, 0);
      expect(camera.created, isEmpty);
      expect(find.byType(CameraPreview), findsNothing);
      expect(find.textContaining('На этом устройстве'), findsOneWidget);

      await tester.tap(find.text('Импортировать фото'));
      await tester.pump();
      await tester.tap(find.text('Импортировать фото'));
      expect(imports, 1);
      picked.complete(_photoBytes);
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), orderedEquals(_photoBytes));
      expect(camera.created, isEmpty);
    },
    platform: TargetPlatform.linux,
  );

  cameraTestWidgets('torch toggles during composition without taking a photo', (
    tester,
  ) async {
    final result = await _openCapture(tester);
    final light = find.byKey(const ValueKey('calibration-torch'));
    await tester.tap(light);
    await tester.pumpAndSettle();
    expect(camera.flashModes, ['torch']);
    expect(camera.captures, 0);
    await tester.tap(light);
    await tester.pumpAndSettle();
    expect(camera.flashModes, ['torch', 'off']);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(await _cameraResult(tester, result), isNull);
  });

  cameraTestWidgets('unsupported light keeps preview and import usable', (
    tester,
  ) async {
    camera.flashError = 'setFlashModeFailed';
    final result = await _openCapture(
      tester,
      pickImage: () async => _photoBytes,
    );
    await tester.tap(find.byKey(const ValueKey('calibration-torch')));
    await tester.pumpAndSettle();
    expect(find.byType(CameraPreview), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('calibration-torch')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Снять'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Импортировать фото'));
    await tester.pumpAndSettle();
    expect(await _cameraResult(tester, result), orderedEquals(_photoBytes));
    expect(camera.captures, 0);
  });

  cameraTestWidgets('background waits for in-flight light before release', (
    tester,
  ) async {
    final result = await _openCapture(tester);
    camera.flashGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('calibration-torch')));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Снять'))
          .onPressed,
      isNull,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(camera.disposed, isEmpty);
    expect(camera.created, hasLength(1));
    camera.flashGate!.complete();
    await waitForCameraIo(tester, () => camera.created.length == 2);
    expect(camera.flashModes, ['torch', 'off']);
    expect(camera.disposed, contains(camera.ids.first));
    expect(camera.created, hasLength(2));
    expect(find.byType(CameraPreview), findsOneWidget);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(await _cameraResult(tester, result), isNull);
    expect(tester.takeException(), isNull);
  });

  cameraTestWidgets('cancel during light change never reopens the camera', (
    tester,
  ) async {
    final result = await _openCapture(tester);
    camera.flashGate = Completer<void>();
    await tester.tap(find.byKey(const ValueKey('calibration-torch')));
    await tester.pump();
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await _cameraResult(tester, result), isNull);
    expect(camera.disposed, isEmpty);
    camera.flashGate!.complete();
    await waitForCameraIo(
      tester,
      () => camera.disposed.contains(camera.ids.single),
    );
    expect(camera.flashModes, ['torch', 'off']);
    expect(camera.disposed, contains(camera.ids.single));
    expect(camera.created, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  cameraTestWidgets('cancel disposes a late initialization without reopening', (
    tester,
  ) async {
    camera.initializeGate = Completer<void>();
    final result = await _openCapture(tester, waitUntilReady: false);
    expect(camera.created, hasLength(1));
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await _cameraResult(tester, result), isNull);
    expect(camera.disposed, isEmpty);

    camera.initializeGate!.complete();
    await tester.pumpAndSettle();
    expect(camera.disposed, contains(camera.ids.single));
    expect(camera.created, hasLength(1));
    expect(camera.captures, 0);
    expect(tester.takeException(), isNull);
  });

  cameraTestWidgets('back during a pending shutter discards the late photo', (
    tester,
  ) async {
    camera.pictureGate = Completer<String>();
    final path = (await tester.runAsync(camera.makePhoto))!;
    final result = await _openCapture(tester);
    await tester.tap(find.text('Снять'));
    await tester.pump();
    await waitForCameraIo(tester, () => camera.captures == 1);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pump(const Duration(milliseconds: 400));
    // The outgoing route is still animating, but its preview must already be
    // detached before the shutter's notifier can finish and be disposed.
    expect(find.byType(CameraPreview), findsNothing);
    expect(await _cameraResult(tester, result), isNull);
    expect(camera.disposed, isEmpty);

    // A cancelled shutter still owns and must release its late capture file.
    camera.pictureGate!.complete(path);
    await waitForCameraIo(
      tester,
      () => camera.disposed.contains(camera.ids.single),
    );
    expect(await tester.runAsync(() => File(path).exists()), isFalse);
    expect(camera.disposed, contains(camera.ids.single));
    expect(camera.captures, 1);
    expect(find.text('Открыть камеру'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  cameraTestWidgets(
    'foreground restart waits until the old session is released',
    (tester) async {
      final result = await _openCapture(tester);
      camera.disposeGate = Completer<void>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byType(CameraPreview), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(camera.created, hasLength(1));

      camera.disposeGate!.complete();
      await waitForCameraIo(tester, () => camera.created.length == 2);
      expect(camera.disposed, contains(camera.ids.first));
      expect(camera.created, hasLength(2));
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(camera.captures, 0);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets('backgrounding during capture cancels only that shutter', (
    tester,
  ) async {
    camera.pictureGate = Completer<String>();
    final path = (await tester.runAsync(camera.makePhoto))!;
    final result = await _openCapture(tester);
    await tester.tap(find.text('Снять'));
    await tester.pump();
    await waitForCameraIo(tester, () => camera.captures == 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(camera.created, hasLength(1));
    expect(camera.disposed, isEmpty);
    camera.pictureGate!.complete(path);
    await waitForCameraIo(
      tester,
      () => camera.disposed.contains(camera.ids.first),
    );
    expect(await tester.runAsync(() => File(path).exists()), isFalse);
    expect(camera.created, hasLength(2));
    expect(camera.disposed, contains(camera.ids.first));
    expect(find.byType(CameraPreview), findsOneWidget);
    expect(result.isCompleted, isFalse);
    expect(camera.captures, 1);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(await _cameraResult(tester, result), isNull);
    expect(tester.takeException(), isNull);
  });

  for (final code in [
    'CameraAccessDenied',
    'CameraAccessDeniedWithoutPrompt',
    'CameraAccessRestricted',
  ]) {
    cameraTestWidgets('$code is actionable without a resume permission loop', (
      tester,
    ) async {
      camera.accessError = code;
      camera.createGate = Completer<void>();
      final result = await _openCapture(
        tester,
        pickImage: () async => _photoBytes,
        waitUntilReady: false,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      camera.createGate!.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('настройк'), findsOneWidget);
      expect(find.text('Повторить'), findsOneWidget);
      expect(camera.created, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(camera.created, hasLength(1));
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(camera.created, hasLength(2));
      await tester.tap(find.text('Импортировать фото'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), orderedEquals(_photoBytes));
      expect(camera.captures, 0);
    });
  }

  cameraTestWidgets(
    'permission-dialog interruption can finish an approved preview',
    (tester) async {
      camera.createGate = Completer<void>();
      final result = await _openCapture(tester, waitUntilReady: false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      camera.createGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(camera.created, hasLength(1));
      expect(camera.captures, 0);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets(
    'no camera offers retry and import instead of a dead preview',
    (tester) async {
      camera.noCamera = true;
      final result = await _openCapture(tester);
      expect(find.textContaining('Задняя камера не найдена'), findsOneWidget);
      expect(camera.created, isEmpty);
      camera.noCamera = false;
      await tester.tap(find.text('Повторить'));
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsOneWidget);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets(
    'runtime camera error releases the session and permits import',
    (tester) async {
      final result = await _openCapture(
        tester,
        pickImage: () async => _photoBytes,
      );
      camera.sendEvent(camera.ids.single, 'error', {
        'description': 'Camera lost',
      });
      await waitForCameraIo(
        tester,
        () => camera.disposed.contains(camera.ids.single),
      );
      expect(find.byType(CameraPreview), findsNothing);
      expect(camera.disposed, contains(camera.ids.single));
      await tester.tap(find.text('Импортировать фото'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), orderedEquals(_photoBytes));
    },
  );

  cameraTestWidgets('cancelled import reopens one previously working session', (
    tester,
  ) async {
    final picked = Completer<Uint8List?>();
    var pickerOpened = false;
    final result = await _openCapture(
      tester,
      pickImage: () {
        pickerOpened = true;
        expect(camera.disposed, contains(camera.ids.first));
        return picked.future;
      },
    );
    await tester.tap(find.text('Импортировать фото'));
    await waitForCameraIo(tester, () => pickerOpened);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(camera.created, hasLength(1));
    picked.complete(null);
    await waitForCameraIo(tester, () => camera.created.length == 2);
    expect(camera.created, hasLength(2));
    expect(find.byType(CameraPreview), findsOneWidget);
    expect(result.isCompleted, isFalse);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(await _cameraResult(tester, result), isNull);
  });

  cameraTestWidgets(
    'late gallery result cannot pop the route behind a cancellation',
    (tester) async {
      final picked = Completer<Uint8List?>();
      final result = await _openCapture(tester, pickImage: () => picked.future);
      await tester.tap(find.text('Импортировать фото'));
      await tester.pump();
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
      picked.complete(_photoBytes);
      await tester.pumpAndSettle();
      expect(find.text('Открыть камеру'), findsOneWidget);
      expect(camera.created, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  cameraTestWidgets(
    'failed import remains actionable instead of vanishing on resume',
    (tester) async {
      final result = await _openCapture(
        tester,
        pickImage: () async => throw const FormatException('Unreadable file'),
      );
      await tester.tap(find.text('Импортировать фото'));
      await waitForCameraIo(tester, () => _retryEnabled(tester));
      expect(find.byType(CameraPreview), findsNothing);
      expect(camera.created, hasLength(1));
      expect(result.isCompleted, isFalse);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets(
    'empty imported photo is rejected without closing the page',
    (tester) async {
      final result = await _openCapture(
        tester,
        pickImage: () async => Uint8List(0),
      );
      await tester.tap(find.text('Импортировать фото'));
      await waitForCameraIo(tester, () => _retryEnabled(tester));
      expect(find.byType(CameraPreview), findsNothing);
      expect(camera.created, hasLength(1));
      expect(result.isCompleted, isFalse);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets(
    'backgrounding while releasing a camera does not launch import',
    (tester) async {
      var imports = 0;
      final result = await _openCapture(
        tester,
        pickImage: () async {
          imports++;
          return null;
        },
      );
      camera.disposeGate = Completer<void>();
      await tester.tap(find.text('Импортировать фото'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      camera.disposeGate!.complete();
      await tester.pump();
      expect(imports, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await waitForCameraIo(
        tester,
        () => find.byType(CameraPreview).evaluate().isNotEmpty,
      );
      expect(find.byType(CameraPreview), findsOneWidget);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets(
    'initialization completing in background is released before resume',
    (tester) async {
      camera.initializeGate = Completer<void>();
      final result = await _openCapture(tester, waitUntilReady: false);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      camera.initializeGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsNothing);
      expect(camera.disposed, contains(camera.ids.first));
      expect(camera.created, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(camera.created, hasLength(2));
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );
  cameraTestWidgets(
    'native stream startup failure keeps camera and import usable',
    (tester) async {
      camera.streamStartError = true;
      final result = await _openCapture(
        tester,
        pickImage: () async => _photoBytes,
      );
      expect(
        find.byKey(const ValueKey('calibration-stream-unavailable')),
        findsOneWidget,
      );
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Снять'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Импортировать фото'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), orderedEquals(_photoBytes));
    },
  );

  cameraTestWidgets('only measured frames draw paper and cross overlays', (
    tester,
  ) async {
    final result = await _openCapture(tester);
    camera.sendFrame(bytes: _measuredLuma(), width: 480, height: 480);
    await waitForCameraIo(
      tester,
      () => find
          .byKey(const ValueKey('calibration-live-overlay'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      find.byKey(const ValueKey('calibration-processed-image')),
      findsOneWidget,
    );
    expect(camera.captures, 0);
    await tester.tap(find.byKey(const ValueKey('calibration-preview-raw')));
    expect(
      find.byKey(const ValueKey('calibration-live-guidance')),
      findsOneWidget,
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('calibration-live-overlay')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('calibration-preview-mask')));
    await tester.pump(const Duration(milliseconds: 600));
    camera.sendFrame();
    await waitForCameraIo(
      tester,
      () => find
          .byKey(const ValueKey('calibration-live-overlay'))
          .evaluate()
          .isEmpty,
    );
    expect(
      find.byKey(const ValueKey('calibration-live-guidance')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(await _cameraResult(tester, result), isNull);
  });

  cameraTestWidgets(
    'shutter settles image stream and cancelled stop never captures',
    (tester) async {
      final result = await _openCapture(tester);
      camera.streamStopGate = Completer<void>();
      await tester.tap(find.text('Снять'));
      await tester.pump();
      await waitForCameraIo(tester, () => camera.streamStops == 1);
      expect(camera.streamStops, 1);
      expect(camera.captures, 0);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(await _cameraResult(tester, result), isNull);
      expect(camera.disposed, isEmpty);
      camera.streamStopGate!.complete();
      await waitForCameraIo(
        tester,
        () => camera.disposed.contains(camera.ids.single),
      );
      expect(camera.captures, 0);
      expect(camera.disposed, contains(camera.ids.single));
      expect(tester.takeException(), isNull);
    },
  );

  cameraTestWidgets('live processing changes actual pixels before shutter', (
    tester,
  ) async {
    final result = await _openCapture(tester);
    expect(camera.streamStarts, 1);
    await tester.tap(find.byKey(const ValueKey('calibration-preview-tone')));
    camera.sendFrame();
    await waitForCameraIo(
      tester,
      () => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((w) => w.image != null),
    );
    final before = tester
        .widget<RawImage>(
          find.byKey(const ValueKey('calibration-processed-image')),
        )
        .image!;
    final beforePixels = (await tester.runAsync(() => _imagePixels(before)))!;
    final brightness = tester.widget<Slider>(
      find.byKey(const ValueKey('calibration-brightness')),
    );
    brightness.onChanged!(40);
    await tester.pump();
    camera.sendFrame();
    await waitForCameraIo(
      tester,
      () => tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((w) => w.image != null && !identical(w.image, before)),
    );
    final after = tester
        .widget<RawImage>(
          find.byKey(const ValueKey('calibration-processed-image')),
        )
        .image!;
    final afterPixels = (await tester.runAsync(() => _imagePixels(after)))!;
    expect(afterPixels.first, beforePixels.first + 40);
    expect(camera.captures, 0);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(await _cameraResult(tester, result), isNull);
  });

  cameraTestWidgets(
    'software controls are baked into captured and imported pixels',
    (tester) async {
      for (final importing in [false, true]) {
        final result = await _openCapture(
          tester,
          pickImage: () async => _photoBytes,
        );
        tester
            .widget<Slider>(
              find.byKey(const ValueKey('calibration-brightness')),
            )
            .onChanged!(-40);
        tester
            .widget<Slider>(find.byKey(const ValueKey('calibration-contrast')))
            .onChanged!(0.5);
        await tester.pump();
        if (importing) {
          await tester.tap(find.text('Импортировать фото'));
        } else {
          final path = (await tester.runAsync(camera.makePhoto))!;
          camera.pictureGate = Completer<String>()..complete(path);
          await tester.tap(find.text('Снять'));
        }
        await waitForCameraIo(tester, () => result.isCompleted);
        final bytes = (await result.future)!;
        expect(bytes, isNot(orderedEquals(_photoBytes)));
        final pixels = await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(bytes);
          final image = (await codec.getNextFrame()).image;
          try {
            return await _imagePixels(image);
          } finally {
            image.dispose();
            codec.dispose();
          }
        });
        // The fixture is opaque white: (255 - 128) * .5 + 128 - 40 = 151.5.
        expect(pixels!.take(4), [152, 152, 152, 255]);
        if (!importing) {
          expect(
            camera.operations.indexOf('stopStream'),
            lessThan(camera.operations.indexOf('capture')),
          );
        }
      }
    },
  );

  cameraTestWidgets(
    'nonidentity import bounds decoded dimensions before transforming',
    (tester) async {
      final original = (await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.white, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(2000, 40);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          return png!.buffer.asUint8List();
        } finally {
          image.dispose();
          picture.dispose();
        }
      }))!;
      final result = await _openCapture(
        tester,
        pickImage: () async => original,
      );
      tester
          .widget<Slider>(find.byKey(const ValueKey('calibration-brightness')))
          .onChanged!(-10);
      await tester.pump();
      await tester.tap(find.text('Импортировать фото'));
      await waitForCameraIo(tester, () => result.isCompleted);
      final bytes = (await result.future)!;
      final dimensions = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        try {
          return (image.width, image.height);
        } finally {
          image.dispose();
          codec.dispose();
        }
      });
      expect(dimensions, (1800, 36));
    },
  );

  cameraTestWidgets(
    'EV writes coalesce and finish before shutter and release',
    (tester) async {
      final result = await _openCapture(tester);
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('calibration-exposure')),
      );
      expect(slider.min, -4);
      expect(slider.max, 4);
      expect(slider.divisions, 48);
      camera.exposureGate = Completer<void>();
      slider.onChanged!(-1);
      slider.onChanged!(-2);
      slider.onChanged!(-3);
      await tester.pump();
      expect(camera.exposures, [-1]);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Снять'))
            .onPressed,
        isNull,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(camera.disposed, isEmpty);
      camera.exposureGate!.complete();
      await waitForCameraIo(tester, () => camera.created.length == 2);
      expect(camera.exposures, [-1, -3]);
      expect(camera.created, hasLength(2));
      final resumed = tester.widget<Slider>(
        find.byKey(const ValueKey('calibration-exposure')),
      );
      expect(resumed.value, -3);
      expect(
        camera.operations.indexOf('exposure:-1.0'),
        lessThan(camera.operations.indexOf('dispose')),
      );
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets(
    'index-valued native EV acknowledgements release shutter before and after resume',
    (tester) async {
      camera.exposureReturnsIndex = true;
      final result = await _openCapture(tester);
      Future<void> changeExposure(double ev) async {
        final acknowledgement = Completer<void>();
        camera.exposureGate = acknowledgement;
        tester
            .widget<Slider>(find.byKey(const ValueKey('calibration-exposure')))
            .onChanged!(ev);
        await tester.pump();
        // An unintended retry must block rather than spin the test event loop.
        camera.exposureGate = Completer<void>();
        acknowledgement.complete();
        await waitForCameraIo(
          tester,
          () =>
              tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Снять'),
                  )
                  .onPressed !=
              null,
        );
        camera.exposureGate!.complete();
        camera.exposureGate = null;
      }

      await changeExposure(-1);
      expect(camera.exposures, [-1]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await waitForCameraIo(tester, () => camera.created.length == 2);
      await changeExposure(-2);
      expect(camera.exposures, [-1, -1, -2]);
      await tester.tap(find.byTooltip('Отмена'));
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets(
    'raw mode keeps processing and unsupported frames are explicit',
    (tester) async {
      final result = await _openCapture(tester);
      await tester.tap(find.byKey(const ValueKey('calibration-preview-raw')));
      camera.sendFrame();
      await waitForCameraIo(
        tester,
        () => find
            .byKey(const ValueKey('calibration-live-guidance'))
            .evaluate()
            .isNotEmpty,
      );
      expect(find.byType(CameraPreview), findsOneWidget);
      camera.sendFrame(format: 256);
      await tester.pump(const Duration(milliseconds: 600));
      camera.sendFrame(format: 256);
      await waitForCameraIo(
        tester,
        () => find
            .byKey(const ValueKey('calibration-stream-unavailable'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('calibration-stream-unavailable')),
        findsOneWidget,
      );
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(camera.captures, 0);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await _cameraResult(tester, result), isNull);
    },
  );

  cameraTestWidgets(
    'dragging controls keeps processed frames visible and labels pending settings',
    (tester) async {
      final result = await _openCapture(tester);
      await tester.tap(find.byKey(const ValueKey('calibration-preview-tone')));
      await tester.pump();
      final luma = Uint8List.fromList(List<int>.filled(64 * 64, 60));
      camera.sendFrame(bytes: luma);
      await tester.pump();
      final brightness = tester.widget<Slider>(
        find.byKey(const ValueKey('calibration-brightness')),
      );
      brightness.onChanged!(20);
      brightness.onChanged!(40);
      await tester.pump();
      final imageFinder = find.byKey(
        const ValueKey('calibration-processed-image'),
      );
      await waitForCameraIo(tester, () => imageFinder.evaluate().isNotEmpty);
      final pending = tester.widget<RawImage>(imageFinder).image!;
      expect((await tester.runAsync(() => _imagePixels(pending)))!.first, 51);
      expect(
        find.byKey(const ValueKey('calibration-preview-updating')),
        findsOneWidget,
      );
      camera.sendFrame(bytes: luma);
      await waitForCameraIo(
        tester,
        () =>
            imageFinder.evaluate().isNotEmpty &&
            !identical(tester.widget<RawImage>(imageFinder).image, pending),
      );
      final updated = tester.widget<RawImage>(imageFinder).image!;
      expect((await tester.runAsync(() => _imagePixels(updated)))!.first, 91);
      expect(
        find.byKey(const ValueKey('calibration-preview-updating')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 600));
      camera.sendFrame();
      await tester.pump();
      await tester.tap(find.byTooltip('Отмена'));
      expect(await _cameraResult(tester, result), isNull);
      expect(find.byType(RawImage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  cameraTestWidgets('controls fit narrow short phone without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = await _openCapture(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('calibration-brightness')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(await _cameraResult(tester, result), isNull);
  });
}

Uint8List _measuredLuma() {
  final pixels = Uint8List(480 * 480);
  for (var py = 0; py < 480; py++) {
    final y = (py + .5 - 80) / 3;
    for (var px = 0; px < 480; px++) {
      final x = (px + .5 - 80) / 3;
      final dx = x - x.clamp(0, 96);
      final dy = y - y.clamp(4, 92);
      final paper =
          x >= -12 && x < 108 && y >= -8 && y < 104 && dx * dx + dy * dy <= 144;
      var ink = false;
      if (paper) {
        for (final cx in [16.5, 63.5]) {
          for (final cy in [16.5, 56.5]) {
            final mx = (x - cx).abs(), my = (y - cy).abs();
            if ((mx < 1.5 && my < 6.5) || (my < 1.5 && mx < 6.5)) ink = true;
          }
        }
        if (x >= 0 && x < 80 && y >= 0 && y < 96) {
          final ix = x.floor(), iy = y.floor();
          final xtick = ix % 40 == 0 ? 9 : 5;
          final ytick = iy % 40 == 0 ? 9 : 5;
          ink =
              ink ||
              (ix % 8 == 0 && (y < xtick || y >= 96 - xtick)) ||
              (iy % 8 == 0 && (x < ytick || x >= 80 - ytick));
        }
      }
      pixels[py * 480 + px] = paper ? (ink ? 24 : 215) : 20;
    }
  }
  return pixels;
}

Future<Uint8List?> _cameraResult(
  WidgetTester tester,
  Completer<Uint8List?> result,
) async {
  await waitForCameraIo(tester, () => result.isCompleted);
  return result.future;
}

bool _retryEnabled(WidgetTester tester) {
  final retry = find.widgetWithText(TextButton, 'Повторить');
  return retry.evaluate().isNotEmpty &&
      tester.widget<TextButton>(retry).onPressed != null;
}

Future<void> waitForCameraIo(
  WidgetTester tester,
  bool Function() completed,
) async {
  bool settled() =>
      completed() && find.byType(CircularProgressIndicator).evaluate().isEmpty;
  final deadline = Stopwatch()..start();
  while (!settled() && deadline.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(
    settled(),
    isTrue,
    reason:
        'Camera transition did not finish: ${tester.widgetList<Text>(find.byType(Text)).map((widget) => widget.data).join(" | ")}',
  );
  await tester.pumpAndSettle();
}

final _photoBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGP4DwQACfsD/fteaysAAAAASUVORK5CYII=',
);

Future<Completer<Uint8List?>> _openCapture(
  WidgetTester tester, {
  Future<Uint8List?> Function()? pickImage,
  bool waitUntilReady = true,
}) async {
  final result = Completer<Uint8List?>();
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result.complete(
                await captureCalibrationPhoto(
                  context,
                  pickImage: pickImage ?? () async => null,
                ),
              );
            },
            child: const Text('Открыть камеру'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть камеру'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  if (waitUntilReady) {
    await waitForCameraIo(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
    );
  }
  return result;
}

class _StreamingMethodChannelCamera extends MethodChannelCamera {
  @override
  bool supportsImageStreaming() => true;
}

class _CameraHost {
  static const channel = MethodChannel('plugins.flutter.io/camera');
  static int _nextId = 0;
  final ids = <int>[];
  final created = <Map<Object?, Object?>>[];
  final disposed = <int>[];
  final directories = <Directory>[];
  int captures = 0;
  int enumerations = 0;
  Completer<String>? pictureGate;
  Completer<void>? createGate;
  Completer<void>? initializeGate;
  Completer<void>? disposeGate;
  Completer<void>? flashGate;
  String? flashError;
  final flashModes = <String>[];
  String? accessError;
  static const streamChannel = MethodChannel(
    'plugins.flutter.io/camera/imageStream',
  );
  int streamStarts = 0;
  int streamStops = 0;
  bool streamStartError = false;
  bool exposureReturnsIndex = false;
  Completer<void>? exposureGate;
  Completer<void>? streamStopGate;
  final exposures = <double>[];
  final operations = <String>[];
  bool noCamera = false;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(streamChannel, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final arguments = call.arguments;
          switch (call.method) {
            case 'availableCameras':
              enumerations++;
              if (noCamera) return <Map<String, Object>>[];
              return <Map<String, Object>>[
                {
                  'name': 'front',
                  'lensFacing': 'front',
                  'sensorOrientation': 90,
                },
                {'name': 'back', 'lensFacing': 'back', 'sensorOrientation': 90},
              ];
            case 'create':
              created.add(Map<Object?, Object?>.from(arguments as Map));
              await createGate?.future;
              if (accessError case final code?) {
                throw PlatformException(code: code);
              }
              final createdId = ++_nextId;
              ids.add(createdId);
              return {'cameraId': createdId};
            case 'initialize':
              await initializeGate?.future;
              final initializedId = (arguments as Map)['cameraId'] as int;
              sendEvent(initializedId, 'initialized', {
                'previewWidth': 1600.0,
                'previewHeight': 1200.0,
                'exposureMode': 'auto',
                'exposurePointSupported': true,
                'focusMode': 'auto',
                'focusPointSupported': true,
              });
              return null;
            case 'getMinExposureOffset':
              return -4.0;
            case 'getMaxExposureOffset':
              return 4.0;
            case 'getExposureOffsetStepSize':
              return 1.0 / 6;
            case 'setExposureOffset':
              final offset = (arguments as Map)['offset'] as double;
              exposures.add(offset);
              operations.add('exposure:$offset');
              await exposureGate?.future;
              return exposureReturnsIndex ? offset * 6 : offset;
            case 'startImageStream':
              streamStarts++;
              operations.add('startStream');
              if (streamStartError) {
                throw PlatformException(code: 'ImageStreamUnsupported');
              }
              return null;
            case 'stopImageStream':
              streamStops++;
              operations.add('stopStream');
              await streamStopGate?.future;
              return null;
            case 'takePicture':
              captures++;
              operations.add('capture');
              final picture = pictureGate;
              if (picture == null) {
                throw StateError(
                  'Configure a reply before the explicit shutter',
                );
              }
              return picture.future;
            case 'setFlashMode':
              flashModes.add((arguments as Map)['mode'] as String);
              await flashGate?.future;
              if (flashError case final code?) {
                throw PlatformException(code: code);
              }
              return null;
            case 'dispose':
              await disposeGate?.future;
              operations.add('dispose');
              disposed.add((arguments as Map)['cameraId'] as int);
              return null;
            default:
              throw PlatformException(code: 'UnexpectedCameraMethod');
          }
        });
  }

  void sendEvent(int cameraId, String name, Map<String, Object> arguments) {
    TestDefaultBinaryMessengerBinding.instance.channelBuffers.push(
      'flutter.io/cameraPlugin/camera$cameraId',
      const StandardMethodCodec().encodeMethodCall(MethodCall(name, arguments)),
      (_) {},
    );
  }

  void sendFrame({
    int format = 35,
    Uint8List? bytes,
    int width = 64,
    int height = 64,
  }) {
    TestDefaultBinaryMessengerBinding.instance.channelBuffers.push(
      streamChannel.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'format': format,
        'width': width,
        'height': height,
        'planes': [
          {
            'bytes':
                bytes ??
                Uint8List.fromList(
                  List<int>.generate(width * height, (i) => 60 + i % 120),
                ),
            'bytesPerRow': width,
            'bytesPerPixel': 1,
          },
        ],
      }),
      (_) {},
    );
  }

  Future<String> makePhoto() async {
    final directory = await Directory.systemTemp.createTemp(
      'calibration-photo-',
    );
    directories.add(directory);
    final file = File('${directory.path}/photo.png');
    await file.writeAsBytes(_photoBytes);
    return file.path;
  }

  Future<void> removeFiles() async {
    for (final directory in directories) {
      await directory.delete(recursive: true);
    }
  }

  void completePendingRequests() {
    if (createGate case final gate? when !gate.isCompleted) gate.complete();
    if (initializeGate case final gate? when !gate.isCompleted) gate.complete();
    if (pictureGate case final gate? when !gate.isCompleted) {
      gate.complete('/cancelled-and-never-read.png');
    }
    if (disposeGate case final gate? when !gate.isCompleted) gate.complete();
    if (flashGate case final gate? when !gate.isCompleted) gate.complete();
    if (exposureGate case final gate? when !gate.isCompleted) gate.complete();
    if (streamStopGate case final gate? when !gate.isCompleted) gate.complete();
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(streamChannel, null);
  }
}
