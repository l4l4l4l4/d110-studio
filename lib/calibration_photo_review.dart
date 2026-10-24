import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'calibration_photo_analysis.dart';

/// Borrows [image]; the calibration session owns and disposes it.
class CalibrationPhotoPreview extends StatelessWidget {
  const CalibrationPhotoPreview({
    super.key,
    required this.image,
    this.fiducials = const [],
    this.paperOutline = const [],
    this.onTap,
    this.selectedMark,
  });

  final ui.Image image;
  final List<CalibrationPhotoPoint> fiducials;
  final List<CalibrationPhotoPoint> paperOutline;
  final ValueChanged<CalibrationPhotoPoint>? onTap;
  final int? selectedMark;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final rect = _imageRect(image, size);
      return GestureDetector(
        onTapUp: onTap == null
            ? null
            : (event) {
                final p = event.localPosition;
                if (!rect.contains(p)) return;
                onTap!(
                  CalibrationPhotoPoint(
                    (p.dx - rect.left) * image.width / rect.width,
                    (p.dy - rect.top) * image.height / rect.height,
                  ),
                );
              },
        child: CustomPaint(
          size: size,
          painter: _PhotoPainter(
            image,
            fiducials,
            paperOutline,
            Theme.of(context).colorScheme.primary,
            selectedMark,
          ),
        ),
      );
    },
  );
}

Rect _imageRect(ui.Image image, Size size) {
  final fitted = applyBoxFit(
    BoxFit.contain,
    Size(image.width.toDouble(), image.height.toDouble()),
    size,
  ).destination;
  return Alignment.center.inscribe(fitted, Offset.zero & size);
}

class _PhotoPainter extends CustomPainter {
  _PhotoPainter(
    this.image,
    this.marks,
    this.outline,
    this.color,
    this.selected,
  );
  final ui.Image image;
  final List<CalibrationPhotoPoint> marks, outline;
  final Color color;
  final int? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = _imageRect(image, size);
    if (rect.isEmpty) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      rect,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.save();
    canvas.clipRect(rect);
    Offset position(CalibrationPhotoPoint p) => Offset(
      rect.left + p.x * rect.width / image.width,
      rect.top + p.y * rect.height / image.height,
    );
    if (outline.isNotEmpty) {
      final path = Path();
      final first = position(outline.first);
      path.moveTo(first.dx, first.dy);
      for (final point in outline.skip(1)) {
        final p = position(point);
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.black
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5,
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    for (var i = 0; i < marks.length; i++) {
      final p = position(marks[i]);
      final radius = selected == i ? 8.0 : 6.0;
      canvas.drawCircle(
        p,
        radius,
        Paint()
          ..color = Colors.black87
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected == i ? 5 : 4,
      );
      canvas.drawCircle(
        p,
        radius,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected == i ? 3 : 2,
      );
      final text = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontFamily: 'NotoSans',
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      var labelX = p.dx + radius + 3;
      if (labelX + text.width + 2 > rect.right) {
        labelX = p.dx - radius - text.width - 3;
      }
      var labelY = p.dy - radius - text.height - 2;
      if (labelY < rect.top + 1) labelY = p.dy + radius + 2;
      final label = Offset(labelX, labelY);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            label.dx - 2,
            label.dy - 1,
            text.width + 4,
            text.height + 2,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = Colors.black87,
      );
      text.paint(canvas, label);
      text.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PhotoPainter oldDelegate) =>
      image != oldDelegate.image ||
      marks != oldDelegate.marks ||
      outline != oldDelegate.outline ||
      color != oldDelegate.color ||
      selected != oldDelegate.selected;
}

Future<List<CalibrationPhotoPoint>?> showCalibrationMarksEditor(
  BuildContext context, {
  required ui.Image image,
  List<CalibrationPhotoPoint> initial = const [],
}) => Navigator.of(context).push<List<CalibrationPhotoPoint>>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => _MarksEditor(image: image, initial: initial),
  ),
);

class _MarksEditor extends StatefulWidget {
  const _MarksEditor({required this.image, required this.initial});
  final ui.Image image;
  final List<CalibrationPhotoPoint> initial;
  @override
  State<_MarksEditor> createState() => _MarksEditorState();
}

class _MarksEditorState extends State<_MarksEditor> {
  late List<CalibrationPhotoPoint> points = List.of(widget.initial);
  int selected = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Четыре креста'),
      leading: IconButton(
        tooltip: 'Отмена',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close),
      ),
    ),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              'Текст REFERENCE — прямо. Коснитесь креста по стрелке; фото можно приблизить.',
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              for (var i = 0; i < 4; i++)
                ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        const [
                          Icons.north_west,
                          Icons.north_east,
                          Icons.south_west,
                          Icons.south_east,
                        ][i],
                        size: 16,
                        semanticLabel: const [
                          'Верхний левый',
                          'Верхний правый',
                          'Нижний левый',
                          'Нижний правый',
                        ][i],
                      ),
                      const SizedBox(width: 4),
                      Text('${i + 1}'),
                    ],
                  ),
                  selected: selected == i,
                  onSelected: i <= points.length
                      ? (_) => setState(() => selected = i)
                      : null,
                ),
            ],
          ),
          Expanded(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 6,
              child: CalibrationPhotoPreview(
                image: widget.image,
                fiducials: points,
                selectedMark: selected,
                onTap: (point) => setState(() {
                  points = List.of(points);
                  if (selected == points.length) {
                    points.add(point);
                  } else {
                    points[selected] = point;
                  }
                  if (selected < 3) selected++;
                }),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: points.length == 4
                    ? () => Navigator.of(context).pop(points)
                    : null,
                child: const Text('Рассчитать контур'),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
