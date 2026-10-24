import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:d110_studio/calibration_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _CameraHost camera;

  setUp(() {
    camera = _CameraHost();
    camera.install();
  });

  tearDown(() async {
    camera.uninstall();
    await camera.removeFiles();
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
      expect(await result.future, orderedEquals(_photoBytes));
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
      expect(await result.future, orderedEquals(_photoBytes));
      expect(camera.created, isEmpty);
    },
    platform: TargetPlatform.linux,
  );

  cameraTestWidgets('cancel disposes a late initialization without reopening', (
    tester,
  ) async {
    camera.initializeGate = Completer<void>();
    final result = await _openCapture(tester);
    expect(camera.created, hasLength(1));
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await result.future, isNull);
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
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pump(const Duration(milliseconds: 400));
    // The outgoing route is still animating, but its preview must already be
    // detached before the shutter's notifier can finish and be disposed.
    expect(find.byType(CameraPreview), findsNothing);
    expect(await result.future, isNull);
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
      await tester.pumpAndSettle();
      expect(camera.disposed, contains(camera.ids.first));
      expect(camera.created, hasLength(2));
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(camera.captures, 0);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await result.future, isNull);
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
    expect(await result.future, isNull);
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
      expect(await result.future, orderedEquals(_photoBytes));
      expect(camera.captures, 0);
    });
  }

  cameraTestWidgets(
    'permission-dialog interruption can finish an approved preview',
    (tester) async {
      camera.createGate = Completer<void>();
      final result = await _openCapture(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      camera.createGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsOneWidget);
      expect(camera.created, hasLength(1));
      expect(camera.captures, 0);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await result.future, isNull);
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
      expect(await result.future, isNull);
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
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsNothing);
      expect(find.textContaining('Камера остановилась'), findsOneWidget);
      expect(camera.disposed, contains(camera.ids.single));
      await tester.tap(find.text('Импортировать фото'));
      await tester.pumpAndSettle();
      expect(await result.future, orderedEquals(_photoBytes));
    },
  );

  cameraTestWidgets('cancelled import reopens one previously working session', (
    tester,
  ) async {
    final picked = Completer<Uint8List?>();
    final result = await _openCapture(
      tester,
      pickImage: () {
        expect(camera.disposed, contains(camera.ids.first));
        return picked.future;
      },
    );
    await tester.tap(find.text('Импортировать фото'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(camera.created, hasLength(1));
    picked.complete(null);
    await tester.pumpAndSettle();
    expect(camera.created, hasLength(2));
    expect(find.byType(CameraPreview), findsOneWidget);
    expect(result.isCompleted, isFalse);
    await tester.tap(find.byTooltip('Отмена'));
    await tester.pumpAndSettle();
    expect(await result.future, isNull);
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
      expect(await result.future, isNull);
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
      await tester.pumpAndSettle();
      expect(find.textContaining('Не удалось открыть фото'), findsOneWidget);
      expect(find.text('Повторить'), findsOneWidget);
      expect(camera.created, hasLength(1));
      expect(result.isCompleted, isFalse);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await result.future, isNull);
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
      await tester.pumpAndSettle();
      expect(find.textContaining('Файл пуст'), findsOneWidget);
      expect(camera.created, hasLength(1));
      expect(result.isCompleted, isFalse);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await result.future, isNull);
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
      await tester.pumpAndSettle();
      expect(find.byType(CameraPreview), findsOneWidget);
      await tester.tap(find.byTooltip('Отмена'));
      await tester.pumpAndSettle();
      expect(await result.future, isNull);
    },
  );

  cameraTestWidgets(
    'initialization completing in background is released before resume',
    (tester) async {
      camera.initializeGate = Completer<void>();
      final result = await _openCapture(tester);
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
      expect(await result.future, isNull);
    },
  );
}

Future<void> waitForCameraIo(
  WidgetTester tester,
  bool Function() completed,
) async {
  final deadline = Stopwatch()..start();
  while (!completed() && deadline.elapsed < const Duration(seconds: 5)) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(completed(), isTrue, reason: 'Capture cleanup did not finish');
  await tester.pumpAndSettle();
}

final _photoBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l9sAAAAASUVORK5CYII=',
);

Future<Completer<Uint8List?>> _openCapture(
  WidgetTester tester, {
  Future<Uint8List?> Function()? pickImage,
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
  return result;
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
  String? accessError;
  bool noCamera = false;

  void install() {
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
            case 'takePicture':
              captures++;
              final picture = pictureGate;
              if (picture == null) {
                throw StateError(
                  'Configure a reply before the explicit shutter',
                );
              }
              return picture.future;
            case 'dispose':
              await disposeGate?.future;
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
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}
