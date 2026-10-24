import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'camera_capture_native.dart'
    if (dart.library.js_interop) 'camera_capture_web.dart'
    as capture;

/// Takes a still photo inside the app, or imports one with the supplied picker.
/// A cancelled route or picker never produces a photo.
Future<Uint8List?> captureCalibrationPhoto(
  BuildContext context, {
  required Future<Uint8List?> Function() pickImage,
}) => Navigator.of(context).push<Uint8List>(
  MaterialPageRoute(
    builder: (_) => _CalibrationCameraPage(pickImage: pickImage),
    fullscreenDialog: true,
  ),
);

class _CalibrationCameraPage extends StatefulWidget {
  const _CalibrationCameraPage({required this.pickImage});

  final Future<Uint8List?> Function() pickImage;

  @override
  State<_CalibrationCameraPage> createState() => _CalibrationCameraPageState();
}

class _CalibrationCameraPageState extends State<_CalibrationCameraPage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void> _opening = Future<void>.value();
  Future<void> _closing = Future<void>.value();
  Future<Uint8List?>? _capture;
  int _generation = 0;
  bool _loading = false;
  bool _busy = false;
  bool _finished = false;
  bool _active = true;
  bool _resumeAllowed = false;
  bool _releaseFailed = false;
  String? _error;

  // The repository ships Android and web camera hosts; desktop hosts can import.
  bool get _supported =>
      kIsWeb || defaultTargetPlatform == TargetPlatform.android;

  bool _current(int generation) =>
      mounted && !_finished && generation == _generation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _active = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (_supported && _active) _startCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_finished) return;
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      // Do not dispose a controller during initialize(): the native permission
      // dialog itself makes Android inactive. The pending attempt will either
      // finish in the foreground or dispose its own controller before returning.
      if (!_loading) unawaited(_releaseCamera());
    } else if (_resumeAllowed && !_busy && !_loading) {
      _startCamera();
    }
    if (mounted) setState(() {});
  }

  void _startCamera() {
    if (!_supported ||
        !_active ||
        _finished ||
        _busy ||
        _loading ||
        _releaseFailed ||
        _controller != null) {
      return;
    }
    final generation = ++_generation;
    final previousOpening = _opening;
    final previousClosing = _closing;
    setState(() {
      _loading = true;
      _error = null;
    });
    _opening = _openCamera(generation, previousOpening, previousClosing);
  }

  Future<void> _openCamera(
    int generation,
    Future<void> previousOpening,
    Future<void> previousClosing,
  ) async {
    CameraController? pending;
    try {
      // Never open a second native session before the old one is released.
      await previousOpening;
      await previousClosing;
      if (!_current(generation) || !_active || _releaseFailed) return;
      final cameras = await availableCameras();
      if (!_current(generation) || !_active) return;
      final back = cameras.where(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      if (back.isEmpty) {
        throw CameraException('NoBackCamera', 'No back-facing camera');
      }
      pending = CameraController(
        back.first,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await pending.initialize();
      if (pending.value.hasError) {
        throw CameraException('CameraError', pending.value.errorDescription);
      }
      if (!_current(generation)) return;
      // Only a successful initialization permits automatic foreground resume.
      // A denied permission is retried exclusively by the explicit retry button.
      _resumeAllowed = true;
      if (!_active) return;
      _controller = pending;
      pending = null;
      _controller!.addListener(_cameraChanged);
    } catch (error) {
      if (_current(generation)) {
        _resumeAllowed = false;
        _error = _cameraError(error);
      }
    } finally {
      if (pending != null) await _disposeController(pending);
      if (_current(generation)) {
        setState(() => _loading = false);
        // Resume may have arrived while the suspended session was disposing.
        if (_active && _resumeAllowed && _controller == null && !_busy) {
          _startCamera();
        }
      }
    }
  }

  void _cameraChanged() {
    final controller = _controller;
    if (controller == null || !controller.value.hasError || _finished) return;
    _resumeAllowed = false;
    unawaited(_releaseCamera());
    setState(() {
      _error = 'Камера остановилась. Повторите запуск или импортируйте фото.';
    });
  }

  Future<void> _disposeController(CameraController controller) async {
    try {
      await controller.dispose();
    } catch (_) {
      _releaseFailed = true;
      _resumeAllowed = false;
      if (mounted && !_finished) {
        setState(() {
          _error =
              'Закройте и снова откройте экран камеры или импортируйте фото.';
        });
      }
    }
  }

  Future<void> _releaseCamera({bool rebuild = true}) {
    ++_generation;
    _loading = false;
    final controller = _controller;
    if (controller != null && mounted && rebuild) {
      // A popped route stays mounted throughout its reverse animation. Remove
      // its CameraPreview in the parent build before a pending shutter notifies
      // the preview and before the controller's notifier is disposed.
      setState(() => _controller = null);
    } else {
      _controller = null;
    }
    controller?.removeListener(_cameraChanged);
    final previousClosing = _closing;
    final capture = _capture;
    _closing = () async {
      await previousClosing;
      if (capture != null) {
        // takePicture updates its notifier on completion. Wait before disposing
        // that notifier, even when the photo has already been cancelled.
        try {
          await capture;
        } catch (_) {
          // The capture action reports its error if it is still current.
        }
      }
      if (controller != null) await _disposeController(controller);
    }();
    // An initializing controller is locally owned by _openCamera until ready.
    return Future.wait<void>([_opening, _closing]).then((_) {});
  }

  Future<Uint8List?> _readPhoto(
    CameraController controller,
    int generation,
  ) async {
    final file = await controller.takePicture();
    try {
      if (!_current(generation) || !_active) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw CameraException(
          'EmptyPhoto',
          'The camera returned an empty photo',
        );
      }
      return bytes;
    } finally {
      await capture.release(file.path);
    }
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (_busy ||
        _finished ||
        !_active ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture) {
      return;
    }
    final generation = _generation;
    setState(() => _busy = true);
    final capture = _readPhoto(controller, generation);
    _capture = capture;
    try {
      final bytes = await capture;
      if (_current(generation) && _active && bytes != null) {
        await _finish(bytes);
      }
    } catch (error) {
      if (_current(generation)) {
        _resumeAllowed = false;
        unawaited(_releaseCamera());
        setState(() => _error = _cameraError(error));
      }
    } finally {
      if (identical(_capture, capture)) _capture = null;
      if (mounted && !_finished) {
        setState(() => _busy = false);
        if (_active && _resumeAllowed && _controller == null) _startCamera();
      }
    }
  }

  Future<void> _importPhoto() async {
    if (_busy || _finished) return;
    setState(() => _busy = true);
    try {
      await _releaseCamera();
      if (!mounted || _finished || !_active) return;
      final bytes = await widget.pickImage();
      if (!mounted || _finished) return;
      if (bytes != null) {
        if (bytes.isEmpty) {
          _resumeAllowed = false;
          setState(() => _error = 'Файл пуст. Выберите другое фото.');
        } else {
          await _finish(bytes);
        }
      }
    } catch (_) {
      if (mounted && !_finished) {
        _resumeAllowed = false;
        setState(
          () => _error = 'Не удалось открыть фото. Выберите другой файл.',
        );
      }
    } finally {
      if (mounted && !_finished) {
        setState(() => _busy = false);
        if (_active && _resumeAllowed) _startCamera();
      }
    }
  }

  Future<void> _finish(Uint8List bytes) async {
    if (!mounted || _finished) return;
    _finished = true;
    await _releaseCamera();
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent ?? false) {
      Navigator.of(context).pop(bytes);
    }
  }

  @override
  void dispose() {
    _finished = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_releaseCamera(rebuild: false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller != null && controller.value.isInitialized;
    return PopScope<Uint8List>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _finished = true;
          unawaited(_releaseCamera());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Фото калибровки'),
          leading: IconButton(
            tooltip: 'Отмена',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Вся наклейка на тёмном фоне, все четыре метки видны.',
                  textAlign: TextAlign.center,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: ready && _active
                        // CameraPreview owns its orientation-aware AspectRatio;
                        // loose Center constraints preserve it without cropping.
                        ? CameraPreview(controller)
                        : _loading
                        ? const CircularProgressIndicator()
                        : Text(
                            _error ??
                                (!_supported
                                    ? 'На этом устройстве импортируйте фото наклейки.'
                                    : 'Камера выключена. Нажмите «Повторить» или импортируйте фото.'),
                            textAlign: TextAlign.center,
                          ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (_supported)
                      FilledButton.icon(
                        onPressed: ready && _active && !_busy && !_finished
                            ? _takePhoto
                            : null,
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Снять'),
                      ),
                    OutlinedButton.icon(
                      onPressed: !_busy && !_finished ? _importPhoto : null,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Импортировать фото'),
                    ),
                    if (_supported && !ready && !_loading)
                      TextButton(
                        onPressed: !_busy && _active && !_releaseFailed
                            ? _startCamera
                            : null,
                        child: const Text('Повторить'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _cameraError(Object error) {
  if (error is CameraException) {
    return switch (error.code) {
      'CameraAccessDenied' =>
        'Нет доступа к камере. Разрешите его в настройках приложения, повторите или импортируйте фото.',
      'CameraAccessDeniedWithoutPrompt' =>
        'Разрешите камеру в настройках приложения, затем нажмите «Повторить» или импортируйте фото.',
      'CameraAccessRestricted' =>
        'Камера запрещена настройками устройства. Снимите ограничение или импортируйте фото.',
      'NoBackCamera' =>
        'Задняя камера не найдена. Повторите поиск или импортируйте фото.',
      _ =>
        'Не удалось снять фото. Повторите запуск камеры или импортируйте фото.',
    };
  }
  return 'Камера недоступна. Повторите запуск или импортируйте фото.';
}
