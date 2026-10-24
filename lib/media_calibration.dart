import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'calibration_camera.dart';
import 'calibration_photo_analysis.dart';
import 'calibration_photo_review.dart';
import 'image_decode.dart';
import 'media_calibration_session.dart';
import 'media_geometry.dart';
import 'raster.dart';

Future<MediaProfile?> showMediaCalibration(
  BuildContext context, {
  required MediaProfile initial,
  required Future<void> Function(PrinterRaster) printPattern,
  required Future<void> Function(MediaProfile) saveProfile,
  required bool canPrint,
  bool Function()? canPrintNow,
  Listenable? printerChanges,
  Future<Uint8List?> Function()? capturePhoto,
  Future<Uint8List?> Function()? pickImage,
  Future<String?> Function()? readSession,
  Future<void> Function(String)? saveSession,
}) => showDialog<MediaProfile>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _MediaCalibration(
    initial: initial,
    printPattern: printPattern,
    saveProfile: saveProfile,
    canPrint: canPrint,
    canPrintNow: canPrintNow,
    printerChanges: printerChanges,
    capturePhoto: capturePhoto,
    pickImage: pickImage,
    readSession: readSession,
    saveSession: saveSession,
  ),
);

/// Reference prints the actual head coordinate system, deliberately without an
/// assumed paper mask. Verification prints the draft paper outline at its exact
/// integer head/feed translation. Neither operation rescales a dot.
Future<PrinterRaster> renderMediaCalibrationPattern(
  MediaProfile profile, {
  bool verification = false,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  final ink = Paint()
    ..color = Colors.black
    ..isAntiAlias = false;
  final width = profile.rasterRows;
  if (verification) {
    canvas.clipPath(
      profile.paperPath.shift(
        Offset(
          -profile.feedOffsetDots.toDouble(),
          -profile.headOffsetDots.toDouble(),
        ),
      ),
      doAntiAlias: false,
    );
  }
  if (verification) {
    canvas.save();
    canvas.translate(
      -profile.feedOffsetDots.toDouble(),
      -profile.headOffsetDots.toDouble(),
    );
    canvas.clipPath(profile.paperPath, doAntiAlias: false);
    canvas.drawRRect(
      profile.paperRRect.deflate(.5),
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..isAntiAlias = false,
    );
    final safe = profile.safeRect;
    if (!safe.isEmpty) {
      for (final point in [
        safe.center,
        safe.topLeft + const Offset(2, 2),
        safe.bottomRight - const Offset(3, 3),
      ]) {
        canvas.drawRect(Rect.fromLTWH(point.dx - 2, point.dy, 5, 1), ink);
        canvas.drawRect(Rect.fromLTWH(point.dx, point.dy - 2, 1, 5), ink);
      }
    }
    canvas.restore();
  }
  // 1 mm = eight dots. Long ticks identify 5 mm intervals, not a fitted ruler.
  for (var x = 0; x < width; x += mediaDotsPerMm) {
    final tick = x % 40 == 0 ? 9.0 : 5.0;
    canvas.drawRect(Rect.fromLTWH(x.toDouble(), 0, 1, tick), ink);
    canvas.drawRect(
      Rect.fromLTWH(x.toDouble(), printHeadDots - tick, 1, tick),
      ink,
    );
  }
  for (var y = 0; y < printHeadDots; y += mediaDotsPerMm) {
    final tick = y % 40 == 0 ? 9.0 : 5.0;
    canvas.drawRect(Rect.fromLTWH(0, y.toDouble(), tick, 1), ink);
    canvas.drawRect(Rect.fromLTWH(width - tick, y.toDouble(), tick, 1), ink);
  }
  // Four interior fiducials support a scaled photograph without relying on
  // the unmeasured paper edge. Their centers are exact raster coordinates.
  for (final x in [16.0, width - 17.0]) {
    for (final y in [16.0, 56.0]) {
      canvas.drawRect(Rect.fromLTWH(x - 3, y, 7, 1), ink);
      canvas.drawRect(Rect.fromLTWH(x, y - 3, 1, 7), ink);
    }
  }
  final painter = TextPainter(
    text: TextSpan(
      text: verification ? 'CHECK\n8 dots=1mm' : 'REFERENCE\n8 dots=1mm',
      style: const TextStyle(
        color: Colors.black,
        fontSize: 9,
        fontWeight: FontWeight.bold,
        fontFamily: 'NotoSans',
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 2,
  )..layout(maxWidth: (width - 24).toDouble());
  painter.paint(canvas, const Offset(12, 22));
  painter.dispose();
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, printHeadDots);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('Не удалось построить физический эталон');
    }
    final mono = monochromeRgba(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      width,
      printHeadDots,
      const RasterSettings(),
    );
    return rotateForPrinter(mono, width, printHeadDots);
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

class _PhotoInput {
  const _PhotoInput(this.rgba, this.width, this.height, this.rows, this.marks);
  final Uint8List rgba;
  final int width, height, rows;
  final List<CalibrationPhotoPoint>? marks;
}

CalibrationPhotoAnalysis _measurePhoto(_PhotoInput input) =>
    analyzeCalibrationPhoto(
      input.rgba,
      input.width,
      input.height,
      referenceRows: input.rows,
      fiducials: input.marks,
    );

class _MediaCalibration extends StatefulWidget {
  const _MediaCalibration({
    required this.initial,
    required this.printPattern,
    required this.saveProfile,
    required this.canPrint,
    this.canPrintNow,
    this.printerChanges,
    this.capturePhoto,
    this.pickImage,
    this.readSession,
    this.saveSession,
  });
  final MediaProfile initial;
  final Future<void> Function(PrinterRaster) printPattern;
  final Future<void> Function(MediaProfile) saveProfile;
  final bool canPrint;
  final bool Function()? canPrintNow;
  final Listenable? printerChanges;
  final Future<Uint8List?> Function()? capturePhoto, pickImage;
  final Future<String?> Function()? readSession;
  final Future<void> Function(String)? saveSession;

  @override
  State<_MediaCalibration> createState() => _MediaCalibrationState();
}

class _MediaCalibrationState extends State<_MediaCalibration>
    with WidgetsBindingObserver {
  MediaCalibrationSession session = MediaCalibrationSession();
  ui.Image? photoImage;
  Future<void> writes = Future.value();
  bool loading = true, busy = false, recoveryRequired = false;
  bool storageWarning = false;
  String? failure, details;

  bool get canPrint => widget.canPrintNow?.call() ?? widget.canPrint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.printerChanges?.addListener(printerChanged);
    unawaited(load());
  }

  void printerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!loading &&
        !busy &&
        !recoveryRequired &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused)) {
      unawaited(
        store(session).catchError((Object error) {
          if (mounted) {
            setState(() {
              storageWarning = true;
              failure = 'Прогресс не сохранён. Не закрывайте приложение.';
              details = '$error';
            });
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.printerChanges?.removeListener(printerChanged);
    photoImage?.dispose();
    super.dispose();
  }

  Future<void> store(MediaCalibrationSession next) {
    if (widget.saveSession == null) return Future.value();
    final text = next.encode();
    final operation = writes
        .catchError((Object _) {})
        .then((_) => widget.saveSession!(text));
    writes = operation;
    return operation;
  }

  Future<void> load() async {
    ui.Image? restoredImage;
    try {
      final text = await widget.readSession?.call();
      var restored = text == null
          ? MediaCalibrationSession()
          : MediaCalibrationSession.decode(text);
      if (restored.completed) restored = MediaCalibrationSession();
      if (restored.photo != null) {
        restoredImage = (await decodeLabelImage(
          restored.photo!,
          maxDimension: 1800,
          maxPixels: 3240000,
        )).image;
        for (final point in [...restored.fiducials, ...restored.paperOutline]) {
          if (point.x < 0 ||
              point.y < 0 ||
              point.x >= restoredImage.width ||
              point.y >= restoredImage.height) {
            throw const FormatException('Точки контура вне снимка');
          }
        }
      }
      if (!mounted) return;
      setState(() {
        session = restored;
        photoImage = restoredImage;
        restoredImage = null;
        if (session.pendingJob != null) {
          failure = 'Стикер мог выйти. Автоповтора нет.';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          recoveryRequired = true;
          failure = 'Не удалось восстановить калибровку.';
          details = '$error';
        });
      }
    } finally {
      restoredImage?.dispose();
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> go(MediaCalibrationSession next) async {
    if (busy) return;
    setState(() {
      busy = true;
      failure = null;
      details = null;
    });
    try {
      await store(next);
      if (mounted) {
        setState(() {
          session = next;
          recoveryRequired = false;
          storageWarning = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          failure = 'Прогресс не сохранён. Повторите действие.';
          details = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirmNewPrint() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Напечатать ещё один?'),
          content: const Text(
            'Предыдущий стикер мог выйти. Проверьте принтер перед новой печатью.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Печатать новый'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> print({required bool verification}) async {
    if (busy || !canPrint || (verification && session.draft == null)) return;
    if (session.pendingJob != null && !await confirmNewPrint()) return;
    if (!mounted || busy || !canPrint) return;
    final previous = session;
    var submitted = false, acknowledged = false;
    setState(() {
      busy = true;
      failure = null;
      details = null;
    });
    try {
      final profile = verification
          ? session.draft!
          : MediaProfile(lengthMm: 10, widthMm: 12);
      final raster = await renderMediaCalibrationPattern(
        profile,
        verification: verification,
      );
      final pending = verification
          ? session.copyWith(
              step: MediaCalibrationStep.verification,
              pendingJob: CalibrationPrintJob.verification,
              verified: false,
            )
          : MediaCalibrationSession(pendingJob: CalibrationPrintJob.reference);
      await store(pending);
      if (!mounted) return;
      setState(() => session = pending);
      submitted = true;
      await widget.printPattern(raster);
      acknowledged = true;
      if (!mounted) return;
      final next = verification
          ? session.copyWith(
              step: MediaCalibrationStep.confirm,
              clearPendingJob: true,
              verified: true,
            )
          : MediaCalibrationSession(
              step: MediaCalibrationStep.photo,
              referenceRows: raster.height,
              referenceReady: true,
            );
      setState(() {
        session = next;
        if (!verification) {
          photoImage?.dispose();
          photoImage = null;
        }
      });
      await store(next);
      if (mounted) setState(() => storageWarning = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          if (!submitted) session = previous;
          storageWarning = acknowledged;
          failure = acknowledged
              ? 'Напечатано. Прогресс не сохранён; повторять печать не нужно.'
              : submitted
              ? 'Связь прервалась. Стикер мог выйти. Автоповтора нет.'
              : 'Печать не началась. Не удалось подготовить или сохранить шаг.';
          details = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> reuseReference() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Этот эталон уже есть?'),
        content: SizedBox(
          width: 280,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sticky_note_2_outlined, size: 64),
              const SizedBox(height: 12),
              const Text(
                'REFERENCE, четыре креста, короткая шкала. Сфотографируем его — новый печатать не будем.',
              ),
              Text(
                '${session.referenceRows} × 96 точек',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Использовать эталон'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await go(
      MediaCalibrationSession(
        step: MediaCalibrationStep.photo,
        referenceRows: session.referenceRows,
        referenceReady: true,
      ),
    );
  }

  Future<void> capture({bool fromGallery = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      failure = null;
      details = null;
    });
    try {
      final Uint8List? bytes;
      if (fromGallery) {
        bytes = await widget.pickImage?.call();
      } else if (widget.capturePhoto != null) {
        bytes = await widget.capturePhoto!();
      } else {
        bytes = await captureCalibrationPhoto(
          context,
          pickImage: widget.pickImage ?? () async => null,
        );
      }
      if (bytes == null || !mounted) return;
      if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
        throw const FormatException('Выберите фото меньше 32 МиБ.');
      }
      final decoded = await decodeLabelImage(
        bytes,
        maxDimension: 1800,
        maxPixels: 3240000,
      );
      var accepted = false;
      try {
        Uint8List encoded = bytes;
        if (encoded.length > MediaCalibrationSession.maxPhotoBytes) {
          final png = await decoded.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (png == null) {
            throw const FormatException('Не удалось прочитать снимок.');
          }
          encoded = png.buffer.asUint8List(
            png.offsetInBytes,
            png.lengthInBytes,
          );
        }
        if (!mounted) return;
        final next = MediaCalibrationSession(
          step: MediaCalibrationStep.photo,
          referenceRows: session.referenceRows,
          referenceReady: true,
          photo: encoded,
        );
        setState(() {
          photoImage?.dispose();
          photoImage = decoded.image;
          session = next;
          accepted = true;
        });
        await store(next);
        await measure();
      } finally {
        if (!accepted) decoded.image.dispose();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          failure = error is FormatException
              ? error.message
              : 'Не удалось обработать снимок. Попробуйте ещё раз.';
          details = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> measure([List<CalibrationPhotoPoint>? marks]) async {
    final image = photoImage;
    if (image == null) return;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw const FormatException('Не удалось прочитать снимок.');
    }
    final result = await compute(
      _measurePhoto,
      _PhotoInput(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        image.width,
        image.height,
        session.referenceRows,
        marks,
      ),
    );
    if (!mounted) return;
    final profile = MediaProfile(
      lengthMm: result.lengthMm,
      widthMm: result.widthMm,
      radiusMm: result.radiusMm,
      feedOffsetDots: result.feedOffsetDots,
      headOffsetDots: result.headOffsetDots,
      name: widget.initial.name,
    );
    final next = session.copyWith(
      step: MediaCalibrationStep.review,
      draft: profile,
      fiducials: result.fiducials,
      paperOutline: result.paperOutline,
      edgeErrorDots: result.edgeErrorDots,
      verified: false,
    );
    setState(() => session = next);
    await store(next);
  }

  Future<void> correctMarks() async {
    if (busy || photoImage == null) return;
    setState(() => busy = true);
    try {
      final points = await showCalibrationMarksEditor(
        context,
        image: photoImage!,
        initial: session.fiducials,
      );
      if (points == null || !mounted) return;
      setState(() {
        failure = null;
        details = null;
        session = MediaCalibrationSession(
          step: MediaCalibrationStep.photo,
          referenceRows: session.referenceRows,
          referenceReady: true,
          photo: session.photo,
          fiducials: points,
        );
      });
      await store(session);
      await measure(points);
    } catch (error) {
      if (mounted) {
        setState(() {
          failure = error is FormatException
              ? error.message
              : 'Контур не рассчитан. Переснимите стикер.';
          details = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> correctProfile() async {
    if (busy || session.draft == null) return;
    final profile = await showDialog<MediaProfile>(
      context: context,
      builder: (_) => _ProfileEditor(initial: session.draft!),
    );
    if (profile == null || !mounted) return;
    final old = session.draft!;
    final changed =
        old.lengthMm != profile.lengthMm ||
        old.widthMm != profile.widthMm ||
        old.radiusMm != profile.radiusMm ||
        old.feedOffsetDots != profile.feedOffsetDots ||
        old.headOffsetDots != profile.headOffsetDots;
    try {
      final outline = projectCalibrationPaperOutline(
        referenceRows: session.referenceRows,
        fiducials: session.fiducials,
        lengthMm: profile.lengthMm,
        widthMm: profile.widthMm,
        radiusMm: profile.radiusMm,
        feedOffsetDots: profile.feedOffsetDots,
        headOffsetDots: profile.headOffsetDots,
      );
      final image = photoImage!;
      if (outline.any(
        (point) =>
            point.x < 0 ||
            point.y < 0 ||
            point.x >= image.width ||
            point.y >= image.height,
      )) {
        throw const FormatException(
          'Контур вышел за края фото. Переснимите стикер целиком.',
        );
      }
      await go(
        session.copyWith(
          step: MediaCalibrationStep.review,
          draft: profile,
          paperOutline: outline,
          verified: changed ? false : session.verified,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          failure = 'Поправка не применена. Проверьте размер и положение.';
          details = '$error';
        });
      }
    }
  }

  Future<void> save() async {
    if (busy ||
        !session.verified ||
        session.pendingJob != null ||
        session.draft == null) {
      return;
    }
    final profile = session.draft!.copyWith(measuredAt: DateTime.now().toUtc());
    setState(() {
      busy = true;
      failure = null;
      details = null;
    });
    try {
      await widget.saveProfile(profile);
      try {
        await store(MediaCalibrationSession(completed: true));
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Профиль сохранён, но не удалось очистить прогресс калибровки.',
              ),
            ),
          );
        }
      }
      if (mounted) Navigator.of(context).pop(profile);
    } catch (error) {
      if (mounted) {
        setState(() {
          failure =
              'Профиль не сохранён. Повтор сохранения не печатает стикер.';
          details = '$error';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void back() {
    if (busy || loading || session.pendingJob != null) return;
    final next = switch (session.step) {
      MediaCalibrationStep.reference => null,
      MediaCalibrationStep.photo => MediaCalibrationStep.reference,
      MediaCalibrationStep.review => MediaCalibrationStep.photo,
      MediaCalibrationStep.verification => MediaCalibrationStep.review,
      MediaCalibrationStep.confirm => MediaCalibrationStep.review,
    };
    if (next != null) unawaited(go(session.copyWith(step: next)));
  }

  @override
  Widget build(BuildContext context) {
    final step = session.step;
    final index = step.index;
    final titles = [
      'Напечатайте эталон',
      'Снимите стикер',
      'Проверьте контур',
      'Напечатайте проверку',
      'Рамка на своём месте?',
    ];
    final subtitles = [
      'Один короткий отпечаток для измерения ленты.',
      'Наклейте на тёмный фон. Весь стикер и четыре креста — в кадре.',
      'Цветная линия должна идти точно по краю бумаги.',
      'Проверим найденные размеры и положение печати.',
      'Сверьте рамку с краями стикера в зоне печати.',
    ];
    final needPrinter =
        step == MediaCalibrationStep.verification ||
        (step == MediaCalibrationStep.reference && !session.referenceReady);
    final primaryLabel = recoveryRequired
        ? 'Начать заново'
        : switch (step) {
            MediaCalibrationStep.reference =>
              session.referenceReady ? 'Продолжить' : 'Печатать эталон',
            MediaCalibrationStep.photo =>
              photoImage == null ? 'Снять фото' : 'Снять заново',
            MediaCalibrationStep.review => 'Контур совпадает',
            MediaCalibrationStep.verification =>
              session.pendingJob == null
                  ? 'Печатать проверку'
                  : 'Повторить проверку',
            MediaCalibrationStep.confirm => 'Совпало — сохранить',
          };
    void primary() {
      if (recoveryRequired) {
        unawaited(go(MediaCalibrationSession()));
      } else {
        switch (step) {
          case MediaCalibrationStep.reference:
            if (session.referenceReady) {
              unawaited(go(session.copyWith(step: MediaCalibrationStep.photo)));
            } else {
              unawaited(print(verification: false));
            }
          case MediaCalibrationStep.photo:
            unawaited(capture());
          case MediaCalibrationStep.review:
            unawaited(
              go(
                session.copyWith(
                  step: session.verified
                      ? MediaCalibrationStep.confirm
                      : MediaCalibrationStep.verification,
                ),
              ),
            );
          case MediaCalibrationStep.verification:
            unawaited(print(verification: true));
          case MediaCalibrationStep.confirm:
            unawaited(save());
        }
      }
    }

    final showPhoto =
        photoImage != null &&
        (step == MediaCalibrationStep.photo ||
            step == MediaCalibrationStep.review);
    return PopScope(
      canPop: !busy && !loading,
      child: Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: SizedBox(
          width: 600,
          height: 760,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    if (index > 0 && !recoveryRequired)
                      IconButton(
                        onPressed: busy || loading || session.pendingJob != null
                            ? null
                            : back,
                        icon: const Icon(Icons.arrow_back),
                        tooltip: session.pendingJob == null
                            ? 'Предыдущий шаг'
                            : 'Результат печати неизвестен',
                      ),
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text('Калибровка ленты'),
                      ),
                    ),
                    Text(
                      '${index + 1} / 5',
                      semanticsLabel: 'Шаг ${index + 1} из 5',
                    ),
                    IconButton(
                      onPressed: busy || loading
                          ? null
                          : () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                      tooltip: 'Закрыть, сохранив прогресс',
                    ),
                  ],
                ),
              ),
              LinearProgressIndicator(
                value: loading || busy ? null : (index + 1) / 5,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recoveryRequired
                          ? 'Продолжение недоступно'
                          : titles[index],
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      recoveryRequired
                          ? 'Сохранённый профиль ленты не изменён.'
                          : subtitles[index],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : recoveryRequired
                    ? const Center(child: Icon(Icons.restore, size: 80))
                    : showPhoto
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: InteractiveViewer(
                          minScale: 1,
                          maxScale: 5,
                          child: CalibrationPhotoPreview(
                            key: const ValueKey('calibration-photo-preview'),
                            image: photoImage!,
                            fiducials: session.fiducials,
                            paperOutline: step == MediaCalibrationStep.review
                                ? session.paperOutline
                                : const [],
                          ),
                        ),
                      )
                    : step == MediaCalibrationStep.reference
                    ? const Center(child: Icon(Icons.print_outlined, size: 112))
                    : step == MediaCalibrationStep.photo
                    ? const Center(
                        child: Icon(Icons.add_a_photo_outlined, size: 112),
                      )
                    : Padding(
                        padding: const EdgeInsets.all(20),
                        child: CustomPaint(
                          key: const ValueKey('media-profile-preview'),
                          painter: _MediaPreview(session.draft!),
                        ),
                      ),
              ),
              if (session.draft != null &&
                  index >= MediaCalibrationStep.review.index)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    '${session.draft!.lengthMm.toStringAsFixed(2)} × ${session.draft!.widthMm.toStringAsFixed(2)} мм · угол R${session.draft!.radiusMm.toStringAsFixed(2)}',
                    textAlign: TextAlign.center,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (failure != null)
                      Text(
                        failure!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (needPrinter && !canPrint && !recoveryRequired)
                      const Text('Подключите принтер для печати.'),
                    const SizedBox(height: 8),
                    FilledButton(
                      key: const ValueKey('calibration-primary'),
                      onPressed:
                          loading ||
                              busy ||
                              (!recoveryRequired && needPrinter && !canPrint)
                          ? null
                          : primary,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(primaryLabel),
                      ),
                    ),
                    if (!recoveryRequired && !loading)
                      switch (step) {
                        MediaCalibrationStep.reference => TextButton(
                          onPressed: busy ? null : reuseReference,
                          child: const Text('Эталон уже есть'),
                        ),
                        MediaCalibrationStep.photo => Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (widget.pickImage != null)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => capture(fromGallery: true),
                                child: const Text('Выбрать фото'),
                              ),
                            if (photoImage != null)
                              TextButton(
                                onPressed: busy ? null : correctMarks,
                                child: const Text('Указать четыре креста'),
                              ),
                          ],
                        ),
                        MediaCalibrationStep.review => Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton(
                              onPressed: busy ? null : correctMarks,
                              child: const Text('Поправить метки'),
                            ),
                            TextButton(
                              onPressed: busy ? null : correctProfile,
                              child: const Text('Размеры'),
                            ),
                          ],
                        ),
                        MediaCalibrationStep.verification => const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'Оранжевое — вне зоны печати.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                        MediaCalibrationStep.confirm => TextButton(
                          onPressed: busy
                              ? null
                              : () => go(
                                  session.copyWith(
                                    step: MediaCalibrationStep.review,
                                  ),
                                ),
                          child: const Text('Не совпало — поправить'),
                        ),
                      },
                    if (storageWarning)
                      TextButton(
                        onPressed: busy ? null : () => go(session),
                        child: const Text('Сохранить прогресс ещё раз'),
                      ),
                    if (details != null)
                      TextButton(
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Подробности'),
                            content: SingleChildScrollView(
                              child: SelectableText(details!),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Закрыть'),
                              ),
                            ],
                          ),
                        ),
                        child: const Text('Подробности ошибки'),
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

class _ProfileEditor extends StatefulWidget {
  const _ProfileEditor({required this.initial});
  final MediaProfile initial;
  @override
  State<_ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<_ProfileEditor> {
  late final fields = <String, TextEditingController>{
    'name': TextEditingController(text: widget.initial.name),
    'length': TextEditingController(text: '${widget.initial.lengthMm}'),
    'width': TextEditingController(text: '${widget.initial.widthMm}'),
    'radius': TextEditingController(text: '${widget.initial.radiusMm}'),
    'feed': TextEditingController(text: '${widget.initial.feedOffsetDots}'),
    'head': TextEditingController(text: '${widget.initial.headOffsetDots}'),
  };

  @override
  void dispose() {
    for (final field in fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  MediaProfile profile() {
    double mm(String name) {
      final value = double.tryParse(
        fields[name]!.text.trim().replaceAll(',', '.'),
      );
      if (value == null || !value.isFinite) {
        throw const FormatException('Укажите размер в миллиметрах.');
      }
      return value;
    }

    int dots(String name) {
      final value = int.tryParse(fields[name]!.text.trim());
      if (value == null) {
        throw const FormatException('Смещение — целое число точек.');
      }
      return value;
    }

    return MediaProfile(
      name: fields['name']!.text.trim(),
      lengthMm: mm('length'),
      widthMm: mm('width'),
      radiusMm: mm('radius'),
      feedOffsetDots: dots('feed'),
      headOffsetDots: dots('head'),
    );
  }

  @override
  Widget build(BuildContext context) {
    MediaProfile? draft;
    String? error;
    try {
      draft = profile();
    } catch (e) {
      error = e is FormatException
          ? e.message
          : 'Проверьте размеры и смещения.';
    }
    return AlertDialog(
      title: const Text('Уточнить размеры'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 100,
              width: double.infinity,
              child: CustomPaint(
                key: const ValueKey('media-profile-preview'),
                painter: _MediaPreview(draft ?? widget.initial),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final (key, label) in [
                      ('name', 'Название ленты'),
                      ('length', 'Длина, мм'),
                      ('width', 'Ширина, мм'),
                      ('radius', 'Радиус угла, мм'),
                      ('feed', 'Смещение по подаче, точек'),
                      ('head', 'Смещение поперёк, точек'),
                    ])
                      TextField(
                        key: ValueKey('media-$key'),
                        controller: fields[key],
                        decoration: InputDecoration(labelText: label),
                        keyboardType: key == 'name'
                            ? TextInputType.text
                            : TextInputType.numberWithOptions(
                                decimal: key != 'feed' && key != 'head',
                                signed: key == 'feed' || key == 'head',
                              ),
                        onChanged: (_) => setState(() {}),
                      ),
                    if (error != null)
                      Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: draft == null ? null : () => Navigator.pop(context, draft),
          child: const Text('Применить'),
        ),
      ],
    );
  }
}

class _MediaPreview extends CustomPainter {
  _MediaPreview(this.profile);
  final MediaProfile profile;
  @override
  void paint(Canvas canvas, Size size) {
    final scale = (size.width / profile.lengthDots)
        .clamp(0.0, size.height / profile.widthDots)
        .toDouble();
    if (scale <= 0) return;
    canvas.save();
    canvas.scale(scale);
    canvas.drawRect(
      Rect.fromLTWH(
        0,
        0,
        profile.rasterRows.toDouble(),
        profile.paperHeightDots.toDouble(),
      ),
      Paint()..color = const Color(0xffbdbdbd),
    );
    canvas.drawPath(
      profile.paperPath,
      Paint()..color = const Color(0xffffcc80),
    );
    canvas.drawPath(profile.printablePath, Paint()..color = Colors.white);
    canvas.drawRRect(
      profile.paperRRect,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 / scale,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MediaPreview oldDelegate) =>
      profile != oldDelegate.profile;
}
