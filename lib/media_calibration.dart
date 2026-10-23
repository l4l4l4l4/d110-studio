import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'media_geometry.dart';
import 'raster.dart';

Future<MediaProfile?> showMediaCalibration(
  BuildContext context, {
  required MediaProfile initial,
  required Future<void> Function(PrinterRaster) printPattern,
  required Future<void> Function(MediaProfile) saveProfile,
  required bool canPrint,
}) => showDialog<MediaProfile>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _MediaCalibration(
    initial: initial,
    printPattern: printPattern,
    saveProfile: saveProfile,
    canPrint: canPrint,
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
      text: verification ? 'CHECK\n8 dots = 1 mm' : 'REFERENCE\n8 dots = 1 mm',
      style: const TextStyle(color: Colors.black, fontSize: 9),
    ),
    textDirection: TextDirection.ltr,
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

class _MediaCalibration extends StatefulWidget {
  const _MediaCalibration({
    required this.initial,
    required this.printPattern,
    required this.saveProfile,
    required this.canPrint,
  });
  final MediaProfile initial;
  final Future<void> Function(PrinterRaster) printPattern;
  final Future<void> Function(MediaProfile) saveProfile;
  final bool canPrint;
  @override
  State<_MediaCalibration> createState() => _MediaCalibrationState();
}

class _MediaCalibrationState extends State<_MediaCalibration> {
  late final Map<String, TextEditingController> fields;
  bool busy = false,
      referencePrinted = false,
      verified = false,
      confirmed = false;
  String? failure;
  int? referenceRows;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    fields = {
      'name': TextEditingController(text: p.name),
      'length': TextEditingController(text: '${p.lengthMm}'),
      'width': TextEditingController(text: '${p.widthMm}'),
      'radius': TextEditingController(text: '${p.radiusMm}'),
      'feed': TextEditingController(text: '${p.feedOffsetDots}'),
      'head': TextEditingController(text: '${p.headOffsetDots}'),
    };
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  MediaProfile draft() {
    double mm(String key) {
      final value = double.tryParse(
        fields[key]!.text.trim().replaceAll(',', '.'),
      );
      if (value == null || !value.isFinite) {
        throw const FormatException('Укажите конечные размеры в миллиметрах.');
      }
      return value;
    }

    int offset(String key) {
      final value = int.tryParse(fields[key]!.text.trim());
      if (value == null) {
        throw const FormatException(
          'Смещение должно быть целым числом точек, без масштабирования.',
        );
      }
      return value;
    }

    return MediaProfile(
      name: fields['name']!.text.trim(),
      lengthMm: mm('length'),
      widthMm: mm('width'),
      radiusMm: mm('radius'),
      feedOffsetDots: offset('feed'),
      headOffsetDots: offset('head'),
    );
  }

  void edited(String _) => setState(() {
    verified = false;
    confirmed = false;
    failure = null;
  });

  Future<void> print({required bool verification}) async {
    if (busy || !widget.canPrint || (verification && !referencePrinted)) return;
    final MediaProfile profile;
    try {
      profile = draft();
    } catch (error) {
      setState(() => failure = '$error');
      return;
    }
    setState(() {
      busy = true;
      failure = null;
      verified = false;
      confirmed = false;
    });
    try {
      final raster = await renderMediaCalibrationPattern(
        profile,
        verification: verification,
      );
      await widget.printPattern(raster);
      if (!mounted) return;
      setState(() {
        if (verification) {
          verified = true;
        } else {
          referencePrinted = true;
          referenceRows = raster.height;
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          if (!verification) {
            referencePrinted = false;
            referenceRows = null;
          }
          failure =
              '$error\nОтпечаток мог выйти. Автоповтора нет. Проверьте принтер; новую печать запускайте только вручную.';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || !referencePrinted || !verified || !confirmed) return;
    final profile = draft().copyWith(measuredAt: DateTime.now().toUtc());
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      await widget.saveProfile(profile);
      if (mounted) Navigator.of(context).pop(profile);
    } catch (error) {
      if (mounted) {
        setState(
          () => failure =
              'Профиль не сохранён: $error. Измерения и проверка сохранены в диалоге; повтор сохранения не печатает стикер.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    MediaProfile? profile;
    String? invalid;
    try {
      profile = draft();
    } catch (error) {
      invalid = '$error';
    }
    final referenceLength =
        referenceRows ?? profile?.rasterRows ?? widget.initial.rasterRows;
    Widget field(
      String key,
      String label, {
      bool signed = false,
      bool name = false,
    }) => SizedBox(
      width: name ? 440 : 212,
      child: TextField(
        key: ValueKey('media-$key'),
        controller: fields[key],
        enabled: !busy,
        decoration: InputDecoration(labelText: label),
        keyboardType: name
            ? TextInputType.text
            : TextInputType.numberWithOptions(decimal: !signed, signed: signed),
        onChanged: name ? (_) => setState(() => failure = null) : edited,
      ),
    );
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('Калибровка физической ленты'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: SizedBox(
                  key: const ValueKey('media-profile-preview'),
                  width: double.infinity,
                  height: 100,
                  child: CustomPaint(
                    painter: _MediaPreview(profile ?? widget.initial),
                  ),
                ),
              ),
              Flexible(
                flex: 4,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        widget.initial.isCalibrated
                            ? 'Повторная калибровка: измерьте ленту и подтвердите новый проверочный отпечаток.'
                            : 'Лента ещё не измерена. Значения ниже — не результат калибровки.',
                      ),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Как измерить и проверить'),
                        children: [
                          const Text(
                            '1. Напечатайте эталон. Номинальная шкала — 8 точек/мм; длинные риски через 5 мм. Для фото наклейте весь стикер на ровный тёмный фон, снимите сверху без изгиба и сохраните все четыре креста. Масштаб точек не растягивается.',
                          ),
                          Text(
                            '${referenceRows == null ? 'Следующий' : 'Подтверждённый'} эталон: $referenceLength × 96 точек. Центры крестов: X=16.5 и ${referenceLength - 16.5}, Y=16.5 и 56.5 (центры пикселей). Координаты подтверждённого эталона не меняются при редактировании размеров.',
                          ),
                          const Text(
                            '2. Измерьте бумагу и начало печати. Длина 10–150 мм, ширина 1–150 мм, радиус от 0 до половины короткой стороны. Дробные миллиметры допустимы. Головка остаётся 96 точек (12 мм), даже если бумага шире.',
                          ),
                          const Text(
                            'Смещения — целые точки: бумажная координата = координата растра + смещение. Положительное смещение оставляет поле в начале бумаги, отрицательное — пустые точки перед её началом. Автоцентрирования нет.',
                          ),
                          const Text(
                            'Белое — бумага под головкой; оранжевое — непечатаемая бумага; серое — вне бумаги. Контур скругляется у каждого отдельного стикера.',
                          ),
                          const Text(
                            '3. Напечатайте проверку. Сверьте контур, поля, кресты и шкалу с фактическим стикером. Непечатаемую часть контура восстанавливайте по измерениям бумаги, а не по отсутствию чернил. Любое изменение размеров требует новой проверки.',
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          field(
                            'name',
                            'Название / марка / партия',
                            name: true,
                          ),
                          field('length', 'Длина по подаче, мм'),
                          field('width', 'Ширина бумаги, мм'),
                          field('radius', 'Радиус угла, мм'),
                          field(
                            'feed',
                            'Начало растра X на бумаге, точек',
                            signed: true,
                          ),
                          field(
                            'head',
                            'Начало головки Y на бумаге, точек',
                            signed: true,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (invalid != null)
                        Text(
                          invalid,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: confirmed,
                        onChanged: !busy && verified && invalid == null
                            ? (value) =>
                                  setState(() => confirmed = value ?? false)
                            : null,
                        title: const Text(
                          'Я измерил бумагу и подтвердил физический проверочный отпечаток',
                        ),
                      ),
                      if (!widget.canPrint)
                        const Text(
                          'Подключите принтер: без физической проверки профиль нельзя отметить измеренным.',
                        ),
                      if (busy) const LinearProgressIndicator(),
                      if (failure != null)
                        Text(
                          failure!,
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
          Wrap(
            spacing: 4,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: const Text('Отмена'),
              ),
              TextButton(
                onPressed: !busy && widget.canPrint && invalid == null
                    ? () => print(verification: false)
                    : null,
                child: const Text('Печатать эталон'),
              ),
              TextButton(
                onPressed:
                    !busy &&
                        widget.canPrint &&
                        referencePrinted &&
                        invalid == null
                    ? () => print(verification: true)
                    : null,
                child: const Text('Печатать проверку'),
              ),
              TextButton(
                onPressed: !busy && verified && confirmed && invalid == null
                    ? save
                    : null,
                child: const Text('Сохранить профиль'),
              ),
            ],
          ),
        ],
      ),
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
