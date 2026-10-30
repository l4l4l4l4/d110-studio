import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'calibration_camera_frame.dart';
import 'calibration_photo_analysis.dart';
import 'calibration_processing.dart';
import 'image_decode.dart';
import 'camera_capture_native.dart'
    if (dart.library.js_interop) 'camera_capture_web.dart'
    as capture;

/// Takes a still photo inside the app, or imports one with the supplied picker.
/// A cancelled route or picker never produces a photo.
Future<Uint8List?> captureCalibrationPhoto(
  BuildContext context, {
  required Future<Uint8List?> Function() pickImage,
  int referenceRows = 80,
}) => Navigator.of(context).push<Uint8List>(
  MaterialPageRoute(
    builder: (_) => _CalibrationCameraPage(
      pickImage: pickImage,
      referenceRows: referenceRows,
    ),
    fullscreenDialog: true,
  ),
);

class _CalibrationCameraPage extends StatefulWidget {
  const _CalibrationCameraPage({
    required this.pickImage,
    required this.referenceRows,
  });

  final Future<Uint8List?> Function() pickImage;
  final int referenceRows;

  @override
  State<_CalibrationCameraPage> createState() => _CalibrationCameraPageState();
}

class _CalibrationCameraPageState extends State<_CalibrationCameraPage>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void> _opening = Future<void>.value();
  Future<void> _closing = Future<void>.value();
  Future<void> _streamOperation = Future<void>.value();
  Future<Uint8List?>? _capture;
  Future<void>? _flashOperation;
  Future<void>? _exposureOperation;
  bool _flashBusy = false;
  bool _flashAvailable = true;
  bool _torchOn = false;
  String? _flashError;
  double? _minExposure, _maxExposure;
  double _exposureStep = 0;
  double _exposure = 0;
  double _appliedExposure = 0;
  String? _exposureError;
  CalibrationImageSettings _settings = const CalibrationImageSettings();
  CalibrationImageSettings? _liveSettings;
  int _settingsRevision = 0;
  bool _showOriginal = false;
  bool _showTone = false;
  bool _frameBusy = false;
  Timer? _frameThrottle;
  ui.Image? _liveImage;
  CalibrationPhotoAnalysis? _liveAnalysis;
  String? _liveGuidance;
  bool _hasLiveResult = false;
  String? _streamError;
  int? _frameRotation;
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
  bool get _exposureBusy => _exposureOperation != null;

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
      // The permission dialog itself makes Android inactive. initialize owns
      // its controller until it can either publish or release that session.
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
        _flashBusy ||
        _exposureBusy ||
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
        imageFormatGroup: kIsWeb ? null : ImageFormatGroup.yuv420,
      );
      await pending.initialize();
      if (pending.value.hasError) {
        throw CameraException('CameraError', pending.value.errorDescription);
      }
      if (!_current(generation)) return;
      _resumeAllowed = true;
      if (!_active) return;
      await _configureExposure(pending);
      if (!_current(generation) || !_active) return;
      _controller = pending;
      pending = null;
      _flashAvailable = true;
      _torchOn = false;
      _flashError = null;
      _streamError = null;
      _frameRotation = null;
      _controller!.addListener(_cameraChanged);
      await _startLiveStream(_controller!, generation);
      if (!_active && _current(generation)) unawaited(_releaseCamera());
    } catch (error) {
      if (_current(generation)) {
        _resumeAllowed = false;
        _error = _cameraError(error);
      }
    } finally {
      if (pending != null) await _disposeController(pending);
      if (_current(generation)) {
        setState(() => _loading = false);
        if (_active && _resumeAllowed && _controller == null && !_busy) {
          _startCamera();
        }
      }
    }
  }

  Future<void> _configureExposure(CameraController controller) async {
    _minExposure = null;
    _maxExposure = null;
    _exposureError = null;
    _appliedExposure = 0;
    try {
      final values = await Future.wait([
        controller.getMinExposureOffset(),
        controller.getMaxExposureOffset(),
        controller.getExposureOffsetStepSize(),
      ]);
      if (!values.every((value) => value.isFinite) ||
          values[0] >= values[1] ||
          values[2] < 0) {
        _exposureError = 'Коррекция EV недоступна';
        return;
      }
      _minExposure = values[0];
      _maxExposure = values[1];
      _exposureStep = values[2];
      _exposure = _roundedExposure(_exposure);
      if (_exposure != 0) {
        await controller.setExposureOffset(_exposure);
        _appliedExposure = _exposure;
      }
    } catch (_) {
      _minExposure = null;
      _maxExposure = null;
      _exposureError = 'Коррекция EV недоступна';
    }
  }

  double _roundedExposure(double value) {
    final rounded = _exposureStep > 0
        ? (value / _exposureStep).round() * _exposureStep
        : value;
    return rounded.clamp(_minExposure!, _maxExposure!).toDouble();
  }

  void _setExposure(double value) {
    final controller = _controller;
    if (controller == null ||
        !_active ||
        _finished ||
        _busy ||
        _flashBusy ||
        _minExposure == null) {
      return;
    }
    setState(() {
      _exposure = _roundedExposure(value);
      _exposureError = null;
      _invalidateLive();
    });
    if (_exposureOperation != null) return;
    final generation = _generation;
    final operation = () async {
      try {
        while (_current(generation) &&
            _active &&
            identical(controller, _controller) &&
            (_appliedExposure - _exposure).abs() > .00001) {
          final target = _exposure;
          // CameraX 0.6.30 returns a compensation index, not the documented EV.
          // We already quantize the requested EV to the driver's step; a
          // successful acknowledgement commits that target, never its units.
          await controller.setExposureOffset(target);
          if (_current(generation)) _appliedExposure = target;
        }
      } catch (_) {
        if (_current(generation)) {
          _exposure = _appliedExposure;
          _exposureError = 'Не удалось изменить EV';
        }
      }
    }();
    _exposureOperation = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_exposureOperation, operation)) _exposureOperation = null;
        if (mounted && !_finished) {
          setState(() {});
          if (_active && _resumeAllowed && _controller == null && !_busy) {
            _startCamera();
          }
        }
      }),
    );
  }

  Future<void> _startLiveStream(CameraController controller, int generation) {
    final previous = _streamOperation;
    final operation = () async {
      await previous;
      if (!_current(generation) || !_active || _busy) return;
      // camera's stream subscription API can report native setup/stream errors
      // through its subscription's zone instead of startImageStream's Future.
      await runZonedGuarded(() async {
        try {
          if (!controller.supportsImageStreaming()) {
            throw UnsupportedError('Image streaming unavailable');
          }
          await controller.startImageStream(
            (image) => _onFrame(image, controller, generation),
          );
        } catch (_) {
          _streamUnavailable(controller, generation);
        }
      }, (_, _) => _streamUnavailable(controller, generation));
    }();
    _streamOperation = operation;
    return operation;
  }

  Future<void> _stopLiveStream(CameraController controller) {
    final previous = _streamOperation;
    final operation = () async {
      try {
        await previous;
      } catch (_) {
        // A failed stop is reported by its caller; disposal must still settle.
      }
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    }();
    _streamOperation = operation;
    return operation;
  }

  void _streamUnavailable(CameraController controller, int generation) {
    if (!_current(generation) || _streamError != null) return;
    setState(() {
      _invalidateLive();
      _streamError =
          'Обработанный live-просмотр недоступен. Доступен оригинал; фото обработается после съёмки.';
    });
    unawaited(
      _stopLiveStream(controller).catchError((Object _) {
        if (!_current(generation)) return;
        _resumeAllowed = false;
        unawaited(_releaseCamera());
        setState(
          () => _error =
              'Не удалось остановить поток камеры. Повторите запуск или импортируйте фото.',
        );
      }),
    );
  }

  void _invalidateLive() {
    ++_settingsRevision;
    _frameThrottle?.cancel();
    _frameThrottle = null;
    _liveImage?.dispose();
    _liveImage = null;
    _liveAnalysis = null;
    _liveGuidance = null;
    _liveSettings = null;
    _hasLiveResult = false;
  }

  void _setSettings({double? brightness, double? contrast}) {
    if (_busy || _finished) return;
    setState(() {
      _settings = CalibrationImageSettings(
        brightness: brightness ?? _settings.brightness,
        contrast: contrast ?? _settings.contrast,
      );
      // Keep completed frames visible while a drag coalesces into the next
      // analysis. Cancelling every in-flight result would starve live preview.
      _frameThrottle?.cancel();
      _frameThrottle = null;
    });
  }

  void _setPreview({required bool original, bool? tone}) {
    setState(() {
      _showOriginal = original;
      if (tone != null && tone != _showTone) {
        _showTone = tone;
        _invalidateLive();
      }
    });
  }

  void _onFrame(
    CameraImage image,
    CameraController controller,
    int generation,
  ) {
    if (!_current(generation) ||
        !_active ||
        _busy ||
        _streamError != null ||
        _flashBusy ||
        _exposureBusy ||
        _frameBusy ||
        _frameThrottle != null ||
        !identical(controller, _controller)) {
      return;
    }
    final rotation = calibrationCameraRotation(
      controller.description.sensorOrientation,
      controller.value.deviceOrientation,
    );
    if (_frameRotation != rotation) {
      _frameRotation = rotation;
      _invalidateLive();
    }
    _frameBusy = true;
    _frameThrottle = Timer(
      const Duration(milliseconds: 500),
      () => _frameThrottle = null,
    );
    final revision = _settingsRevision;
    final settings = _settings;
    final tone = _showTone;
    bool current() =>
        _current(generation) &&
        _active &&
        !_busy &&
        revision == _settingsRevision &&
        rotation ==
            calibrationCameraRotation(
              controller.description.sensorOrientation,
              controller.value.deviceOrientation,
            );
    unawaited(() async {
      ui.Image? rendered;
      try {
        final source = CalibrationCameraFrameSource.fromImage(image);
        final result = await compute(
          _processCameraFrame,
          _CameraFrameAnalysis(
            source,
            rotation,
            widget.referenceRows,
            settings,
          ),
        );
        if (!current()) return;
        rendered = await _rgbaImage(
          tone ? result.processedRgba : result.maskRgba,
          result.width,
          result.height,
        );
        if (!current()) return;
        final previous = _liveImage;
        setState(() {
          _liveImage = rendered;
          _liveSettings = settings;
          _liveAnalysis = result.analysis;
          _liveGuidance = result.guidance;
          _hasLiveResult = true;
        });
        rendered = null;
        previous?.dispose();
      } catch (_) {
        if (current()) _streamUnavailable(controller, generation);
      } finally {
        rendered?.dispose();
        _frameBusy = false;
      }
    }());
  }

  void _cameraChanged() {
    final controller = _controller;
    if (controller == null || _finished) return;
    if (controller.value.hasError) {
      _resumeAllowed = false;
      unawaited(_releaseCamera());
      setState(
        () => _error =
            'Камера остановилась. Повторите запуск или импортируйте фото.',
      );
      return;
    }
    final rotation = calibrationCameraRotation(
      controller.description.sensorOrientation,
      controller.value.deviceOrientation,
    );
    if (_frameRotation != null && rotation != _frameRotation) {
      setState(() {
        _frameRotation = rotation;
        _invalidateLive();
      });
    }
  }

  Future<void> _disposeController(CameraController controller) async {
    try {
      try {
        await _stopLiveStream(controller);
      } catch (_) {
        // Disposal must release the session even if stopping its stream fails.
      }
      if (controller.value.flashMode == FlashMode.torch) {
        try {
          await controller.setFlashMode(FlashMode.off);
        } catch (_) {
          // Disposing the native session remains mandatory if light-off fails.
        }
      }
      await controller.dispose();
    } catch (_) {
      _releaseFailed = true;
      _resumeAllowed = false;
      if (mounted && !_finished) {
        setState(
          () => _error =
              'Закройте и снова откройте экран камеры или импортируйте фото.',
        );
      }
    }
  }

  Future<void> _releaseCamera({bool rebuild = true}) {
    ++_generation;
    _loading = false;
    _invalidateLive();
    final controller = _controller;
    if (controller != null && mounted && rebuild) {
      // Detach the preview during the route's reverse animation, before a late
      // shutter updates or disposes its controller's notifier.
      setState(() => _controller = null);
    } else {
      _controller = null;
    }
    controller?.removeListener(_cameraChanged);
    final previousClosing = _closing;
    final capture = _capture;
    final flash = _flashOperation;
    final exposure = _exposureOperation;
    _closing = () async {
      await previousClosing;
      if (flash != null) await flash;
      if (exposure != null) await exposure;
      if (capture != null) {
        try {
          await capture;
        } catch (_) {
          // The current capture action owns presentation of its error.
        }
      }
      if (controller != null) await _disposeController(controller);
    }();
    return Future.wait<void>([_opening, _closing]).then((_) {});
  }

  Future<Uint8List?> _readPhoto(
    CameraController controller,
    int generation,
    CalibrationImageSettings settings,
  ) async {
    await _stopLiveStream(controller);
    if (!_current(generation) || !_active) return null;
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
      if (!_current(generation) || !_active) return null;
      return await _adjustPhoto(bytes, settings);
    } finally {
      await capture.release(file.path);
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (_busy ||
        _flashBusy ||
        _exposureBusy ||
        !_flashAvailable ||
        _finished ||
        !_active ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    final generation = _generation;
    final enable = !_torchOn;
    setState(() {
      _flashBusy = true;
      _flashError = null;
      _invalidateLive();
    });
    final operation = () async {
      try {
        await controller.setFlashMode(enable ? FlashMode.torch : FlashMode.off);
        if (_current(generation)) {
          _torchOn = controller.value.flashMode == FlashMode.torch;
        }
      } catch (_) {
        if (_current(generation)) {
          _flashAvailable = false;
          _flashError = 'Подсветка недоступна. Используйте внешний свет.';
        }
      }
    }();
    _flashOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_flashOperation, operation)) _flashOperation = null;
      _flashBusy = false;
      if (mounted && !_finished) {
        setState(() {});
        if (_active && _resumeAllowed && _controller == null) _startCamera();
      }
    }
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (_busy ||
        _flashBusy ||
        _exposureBusy ||
        _finished ||
        !_active ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture) {
      return;
    }
    final generation = _generation;
    final settings = _settings;
    setState(() {
      _busy = true;
      _invalidateLive();
    });
    final capture = _readPhoto(controller, generation, settings);
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
    if (_busy || _flashBusy || _exposureBusy || _finished) return;
    final settings = _settings;
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
          final adjusted = await _adjustPhoto(bytes, settings);
          if (mounted && !_finished) await _finish(adjusted);
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

  Widget _slider(
    String key,
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double>? onChanged,
    String caption, {
    int? divisions,
  }) => SizedBox(
    height: 36,
    child: Row(
      children: [
        SizedBox(
          width: 66,
          child: Text(label, style: const TextStyle(fontSize: 12)),
        ),
        Expanded(
          child: Slider(
            key: ValueKey(key),
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            caption,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );

  Widget _preview(CameraController? controller, bool ready) {
    if (!ready || !_active) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Text(
                _error ??
                    (!_supported
                        ? 'На этом устройстве импортируйте фото наклейки.'
                        : 'Камера выключена. Нажмите «Повторить» или импортируйте фото.'),
                textAlign: TextAlign.center,
              ),
      );
    }
    final image = _liveImage;
    if (_showOriginal || image == null || _streamError != null) {
      return Center(child: CameraPreview(controller!));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final fitted = applyBoxFit(
          BoxFit.contain,
          Size(image.width.toDouble(), image.height.toDouble()),
          constraints.biggest,
        ).destination;
        return Center(
          child: SizedBox(
            width: fitted.width,
            height: fitted.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RawImage(
                  key: const ValueKey('calibration-processed-image'),
                  image: image,
                  fit: BoxFit.contain,
                ),
                if (_liveAnalysis case final analysis?)
                  CustomPaint(
                    key: const ValueKey('calibration-live-overlay'),
                    painter: _LiveMeasurementPainter(
                      analysis,
                      image.width,
                      image.height,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _controls(bool ready) {
    final enabled = !_busy && !_finished;
    final cameraEnabled =
        enabled && ready && _active && !_flashBusy && !_exposureBusy;
    final analysis = _liveAnalysis;
    final displayedSettings = _liveSettings;
    final updating =
        displayedSettings != null &&
        (displayedSettings.brightness != _settings.brightness ||
            displayedSettings.contrast != _settings.contrast);
    final guidance =
        _streamError ??
        (updating
            ? 'Обновляем… В кадре: ярк. ${displayedSettings.brightness.round()}, контр. ${displayedSettings.contrast.toStringAsFixed(2)}×.'
            : analysis != null
            ? 'Предпросмотр: ${analysis.lengthMm.toStringAsFixed(1)} × ${analysis.widthMm.toStringAsFixed(1)} мм. Проверка — после съёмки.'
            : _liveGuidance ??
                  (ready
                      ? 'Вся наклейка и 4 метки на тёмном фоне. Ожидание обработки…'
                      : 'Вся наклейка и 4 метки на тёмном фоне.'));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            guidance,
            key: ValueKey(
              _streamError != null
                  ? 'calibration-stream-unavailable'
                  : updating
                  ? 'calibration-preview-updating'
                  : _hasLiveResult
                  ? 'calibration-live-guidance'
                  : 'calibration-live-pending',
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
          if (ready)
            Wrap(
              spacing: 6,
              alignment: WrapAlignment.center,
              children: [
                _previewButton(
                  'calibration-preview-mask',
                  'Маска',
                  !_showOriginal && !_showTone,
                  enabled
                      ? () => _setPreview(original: false, tone: false)
                      : null,
                ),
                _previewButton(
                  'calibration-preview-tone',
                  'Тон',
                  !_showOriginal && _showTone,
                  enabled
                      ? () => _setPreview(original: false, tone: true)
                      : null,
                ),
                _previewButton(
                  'calibration-preview-raw',
                  'Оригинал',
                  _showOriginal,
                  enabled ? () => _setPreview(original: true) : null,
                ),
              ],
            ),
          _slider(
            'calibration-brightness',
            'Яркость',
            _settings.brightness,
            -80,
            80,
            enabled ? (value) => _setSettings(brightness: value) : null,
            _settings.brightness.round().toString(),
            divisions: 160,
          ),
          _slider(
            'calibration-contrast',
            'Контраст',
            _settings.contrast,
            .5,
            2,
            enabled ? (value) => _setSettings(contrast: value) : null,
            '${_settings.contrast.toStringAsFixed(2)}×',
            divisions: 150,
          ),
          if (ready && _minExposure != null && _maxExposure != null)
            _slider(
              'calibration-exposure',
              'Камера EV',
              _exposure,
              _minExposure!,
              _maxExposure!,
              enabled && _active && !_flashBusy ? _setExposure : null,
              '${_exposure >= 0 ? '+' : ''}${_exposure.toStringAsFixed(1)}',
              divisions: _exposureStep > 0
                  ? math.max(
                      1,
                      ((_maxExposure! - _minExposure!) / _exposureStep).round(),
                    )
                  : null,
            ),
          if (_exposureError != null && ready)
            Text(_exposureError!, style: const TextStyle(fontSize: 12)),
          if (_flashError != null)
            Text(
              _flashError!,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 0,
            children: [
              if (_supported)
                FilledButton.icon(
                  onPressed: cameraEnabled ? _takePhoto : null,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Снять'),
                ),
              if (_supported)
                OutlinedButton.icon(
                  key: const ValueKey('calibration-torch'),
                  onPressed: cameraEnabled && _flashAvailable
                      ? _toggleTorch
                      : null,
                  icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
                  label: Text(_torchOn ? 'Свет: вкл' : 'Свет: выкл'),
                ),
              OutlinedButton.icon(
                onPressed: enabled && !_flashBusy && !_exposureBusy
                    ? _importPhoto
                    : null,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Импортировать фото'),
              ),
              if (_supported && !ready && !_loading)
                TextButton(
                  onPressed:
                      enabled &&
                          !_flashBusy &&
                          !_exposureBusy &&
                          _active &&
                          !_releaseFailed
                      ? _startCamera
                      : null,
                  child: const Text('Повторить'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewButton(
    String key,
    String caption,
    bool selected,
    VoidCallback? onPressed,
  ) => TextButton(
    key: ValueKey(key),
    onPressed: onPressed,
    style: TextButton.styleFrom(
      visualDensity: VisualDensity.compact,
      minimumSize: const Size(68, 28),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      backgroundColor: selected
          ? Theme.of(context).colorScheme.secondaryContainer
          : null,
    ),
    child: Text(caption, style: const TextStyle(fontSize: 12)),
  );

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
          toolbarHeight: 48,
          title: const Text('Фото калибровки'),
          leading: IconButton(
            tooltip: 'Отмена',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final preview = Padding(
                padding: const EdgeInsets.all(8),
                child: _preview(controller, ready),
              );
              if (constraints.maxWidth > constraints.maxHeight * 1.3) {
                return Row(
                  children: [
                    Expanded(child: preview),
                    SizedBox(
                      width: math.min(320, constraints.maxWidth * .5),
                      child: SingleChildScrollView(child: _controls(ready)),
                    ),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: preview),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .68,
                    ),
                    child: SingleChildScrollView(child: _controls(ready)),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LiveMeasurementPainter extends CustomPainter {
  _LiveMeasurementPainter(this.analysis, this.width, this.height);
  final CalibrationPhotoAnalysis analysis;
  final int width, height;

  @override
  void paint(Canvas canvas, Size size) {
    Offset position(CalibrationPhotoPoint p) =>
        Offset(p.x * size.width / width, p.y * size.height / height);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final outline = analysis.paperOutline;
    final shadow = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    final accent = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    if (outline.isNotEmpty) {
      final first = position(outline.first);
      final path = Path()..moveTo(first.dx, first.dy);
      for (final point in outline.skip(1)) {
        final p = position(point);
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(path, shadow);
      canvas.drawPath(path, accent);
    }
    accent.color = Colors.orangeAccent;
    for (final mark in analysis.fiducials) {
      final p = position(mark);
      final left = p - const Offset(7, 0), right = p + const Offset(7, 0);
      final top = p - const Offset(0, 7), bottom = p + const Offset(0, 7);
      canvas.drawLine(left, right, shadow);
      canvas.drawLine(top, bottom, shadow);
      canvas.drawLine(left, right, accent);
      canvas.drawLine(top, bottom, accent);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LiveMeasurementPainter oldDelegate) =>
      analysis != oldDelegate.analysis ||
      width != oldDelegate.width ||
      height != oldDelegate.height;
}

class _CameraFrameAnalysis {
  const _CameraFrameAnalysis(
    this.source,
    this.rotation,
    this.referenceRows,
    this.settings,
  );
  final CalibrationCameraFrameSource source;
  final int rotation, referenceRows;
  final CalibrationImageSettings settings;
}

CalibrationLiveResult _processCameraFrame(_CameraFrameAnalysis input) {
  final frame = convertCalibrationCameraFrame(
    input.source,
    rotationDegrees: input.rotation,
  );
  return processCalibrationLiveFrame(
    CalibrationLiveInput(
      rgba: frame.rgba,
      width: frame.width,
      height: frame.height,
      referenceRows: input.referenceRows,
      settings: input.settings,
    ),
  );
}

class _StillAdjustment {
  const _StillAdjustment(this.rgba, this.width, this.height, this.settings);
  final Uint8List rgba;
  final int width, height;
  final CalibrationImageSettings settings;
}

Uint8List _adjustStill(_StillAdjustment input) => adjustCalibrationRgba(
  input.rgba,
  input.width,
  input.height,
  input.settings,
);

Future<ui.Image> _rgbaImage(Uint8List rgba, int width, int height) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
      rowBytes: width * 4,
    );
    codec = await descriptor.instantiateCodec();
    return (await codec.getNextFrame()).image;
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

Future<Uint8List> _adjustPhoto(
  Uint8List bytes,
  CalibrationImageSettings settings,
) async {
  if (settings.brightness == 0 && settings.contrast == 1) return bytes;
  final decoded = await decodeLabelImage(
    bytes,
    maxDimension: 1800,
    maxPixels: 3240000,
  );
  ui.Image? adjusted;
  try {
    final rgba = await decoded.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (rgba == null) {
      throw const FormatException('Не удалось прочитать снимок.');
    }
    final output = await compute(
      _adjustStill,
      _StillAdjustment(
        rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
        decoded.image.width,
        decoded.image.height,
        settings,
      ),
    );
    adjusted = await _rgbaImage(
      output,
      decoded.image.width,
      decoded.image.height,
    );
    final png = await adjusted.toByteData(format: ui.ImageByteFormat.png);
    if (png == null) {
      throw const FormatException('Не удалось обработать снимок.');
    }
    return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    adjusted?.dispose();
    decoded.image.dispose();
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
