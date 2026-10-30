import 'package:flutter/material.dart';

import 'printer_battery.dart';

String _time(DateTime at) =>
    '${at.hour.toString().padLeft(2, '0')}:'
    '${at.minute.toString().padLeft(2, '0')}:'
    '${at.second.toString().padLeft(2, '0')}';

Future<void> showPrinterBattery(
  BuildContext context,
  PrinterBatteryController battery,
) async {
  battery.refresh();
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: AnimatedBuilder(
            animation: battery,
            builder: (context, _) {
              final samples = battery.samples;
              final colors = Theme.of(context).colorScheme;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Expanded(child: Text('Заряд принтера')),
                      IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  Text(
                    battery.percent == null ? '—' : '${battery.percent}%',
                    style: Theme.of(context).textTheme.displayMedium,
                  ),
                  Text(
                    battery.percent == null || samples.isEmpty
                        ? 'Нет свежего замера'
                        : 'Обновлено ${_time(samples.last.at)}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 180,
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 44,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [Text('100%'), Text('50%'), Text('0%')],
                          ),
                        ),
                        Expanded(
                          child: Semantics(
                            label: 'График заряда по фактическим замерам',
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: _BatteryChartPainter(
                                samples,
                                colors.primary,
                                colors.outlineVariant,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (samples.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 44, top: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(_time(samples.first.at)),
                          if (samples.length > 1) Text(_time(samples.last.at)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    samples.length < 2
                        ? 'Новые точки — каждые 30 секунд при подключении.'
                        : 'За время работы приложения · до 24 ч.',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _BatteryChartPainter extends CustomPainter {
  _BatteryChartPainter(this.samples, this.color, this.gridColor)
    : count = samples.length,
      lastAt = samples.isEmpty ? null : samples.last.at;

  final List<PrinterBatterySample> samples;
  final Color color;
  final Color gridColor;
  final int count;
  final DateTime? lastAt;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 4.0;
    final width = size.width - inset * 2;
    final height = size.height - inset * 2;
    if (width <= 0 || height <= 0) return;
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final y = inset + height * fraction;
      canvas.drawLine(Offset(inset, y), Offset(inset + width, y), grid);
    }
    if (samples.isEmpty) return;
    final start = samples.first.at.millisecondsSinceEpoch;
    final elapsed = samples.last.at.millisecondsSinceEpoch - start;
    final span = elapsed > 0 ? elapsed : 1;
    final path = Path();
    Offset? last;
    DateTime? previousAt;
    for (final sample in samples) {
      final fraction = ((sample.at.millisecondsSinceEpoch - start) / span)
          .clamp(0.0, 1.0);
      final point = Offset(
        inset + width * fraction,
        inset + height * (1 - sample.percent / 100),
      );
      // A stopped/backgrounded app did not measure the missing interval.
      if (last == null ||
          sample.at.difference(previousAt!) > const Duration(seconds: 90)) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
      last = point;
      previousAt = sample.at;
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(last!, 4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BatteryChartPainter oldDelegate) =>
      count != oldDelegate.count ||
      lastAt != oldDelegate.lastAt ||
      color != oldDelegate.color ||
      gridColor != oldDelegate.gridColor;
}
