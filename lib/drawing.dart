import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'label.dart' show LabelDocument;
import 'media_geometry.dart';

/// Opens a drawing sheet measured in printer dots, not screen pixels.
///
/// The result is an exactly [width] × [height] black-on-transparent PNG suitable
/// for the existing image LabelElement path. Cancellation returns null. The
/// visible white paper is not included in the PNG. Dimensions must be positive,
/// at most 9600 dots per side and at most 16 megapixels in total.
/// With [trimMargins], dimensions describe adjacent logical safe cells; physical
/// margins are added only when the containing label is rasterized for printing.
Future<Uint8List?> showDrawingEditor(
  BuildContext context, {
  required int width,
  required int height,
  MediaProfile? media,
  int rows = 1,
  int columns = 1,
  bool trimMargins = false,
}) {
  _validateDimensions(width, height);
  return showDialog<Uint8List>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _DrawingEditor(
      width: width,
      height: height,
      media: media,
      rows: rows,
      columns: columns,
      trimMargins: trimMargins,
    ),
  );
}

void _validateDimensions(int width, int height) {
  if (width < 1 ||
      height < 1 ||
      width > 9600 ||
      height > 9600 ||
      width * height > maxMediaCanvasPixels) {
    throw ArgumentError('Drawing dimensions must fit within 9600 dots / 16 MP');
  }
}

/// Converts coordinates on the fitted paper to physical printer dots.
/// Outside points intentionally remain outside: clamping them to the paper
/// would turn an off-paper movement into an unwanted line along its edge.
Offset drawingPoint(Offset local, Size paper, int width, int height) =>
    Offset(local.dx * width / paper.width, local.dy * height / paper.height);

class DrawingStroke {
  DrawingStroke._(Offset first, this.width)
    : _points = [first],
      _path = (Path()..moveTo(first.dx, first.dy)) {
    points = UnmodifiableListView(_points);
  }

  final double width;
  final List<Offset> _points;
  final Path _path;
  late final List<Offset> points;

  void _append(Offset point) {
    _points.add(point);
    _path.lineTo(point.dx, point.dy);
  }
}

/// Bounded stroke history in physical label coordinates.
///
/// Clear retains one recoverable sheet until the next completed stroke; Undo
/// immediately after Clear restores that sheet. A cancelled stroke does not
/// discard this recovery. At most two sheets of [maxPoints] points are retained
/// (the current sheet and that single Clear recovery), without bitmap history.
class DrawingDocument extends ChangeNotifier {
  DrawingDocument({
    required this.width,
    required this.height,
    this.maxPoints = 60000,
    this.maxStrokes = 512,
    this.media,
    this.rows = 1,
    this.columns = 1,
    this.trimMargins = false,
  }) {
    _validateDimensions(width, height);
    final safe = trimMargins ? media?.safeRect : null;
    if (rows < 1 ||
        rows > 8 ||
        columns < 1 ||
        columns > 8 ||
        (trimMargins &&
            (media == null ||
                !LabelDocument.fitsLayout(
                  media!,
                  rows,
                  columns,
                  trimMargins: true,
                ))) ||
        (media != null &&
            (width !=
                    (trimMargins ? safe!.width.toInt() : media!.rasterRows) *
                        columns ||
                height !=
                    (trimMargins
                            ? safe!.height.toInt()
                            : media!.paperHeightDots) *
                        rows))) {
      throw ArgumentError(
        'Размер рисунка должен соответствовать сетке ленты; '
        'обрезка полей требует измеренный безопасный прямоугольник',
      );
    }
    if (maxPoints < 1 || maxStrokes < 1) {
      throw ArgumentError('Drawing limits must be positive');
    }
    strokes = UnmodifiableListView(_strokes);
  }

  final int width, height, maxPoints, maxStrokes;
  final MediaProfile? media;
  final int rows, columns;
  final bool trimMargins;

  Path _gridPath({required bool printable}) {
    if (media == null || trimMargins) {
      return Path()
        ..addRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    }
    final path = Path();
    final tile = printable ? media!.printablePath : media!.paperPath;
    for (var row = 0; row < rows; row++) {
      for (var column = 0; column < columns; column++) {
        path.addPath(
          tile,
          Offset(
            (column * media!.rasterRows).toDouble(),
            (row * media!.paperHeightDots).toDouble(),
          ),
        );
      }
    }
    return path;
  }

  /// Only the presentation is clipped. [exportPng] retains all source ink so
  /// changing the physical profile can reveal it without reconstructing strokes.
  void paintPreview(Canvas canvas) {
    canvas.drawPath(_gridPath(printable: false), Paint()..color = Colors.white);
    canvas.save();
    canvas.clipPath(_gridPath(printable: true), doAntiAlias: false);
    _paint(canvas);
    canvas.restore();
  }

  final List<DrawingStroke> _strokes = [];
  late final List<DrawingStroke> strokes;
  List<DrawingStroke>? _clearUndo;
  DrawingStroke? _active;
  int? _pointer;
  int _pointCount = 0;
  final Paint _brush = Paint()
    ..color = Colors.black
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  bool get isBlank => _strokes.isEmpty;
  bool get isDrawing => _active != null;
  bool get canUndo => isDrawing || !isBlank || _clearUndo != null;
  bool get limitReached =>
      _pointCount + (_active?.points.length ?? 0) >= maxPoints ||
      _strokes.length >= maxStrokes;

  bool beginStroke(int pointer, Offset point, double brushWidth) {
    if (isDrawing ||
        limitReached ||
        !point.dx.isFinite ||
        !point.dy.isFinite ||
        point.dx < 0 ||
        point.dy < 0 ||
        point.dx > width ||
        point.dy > height) {
      return false;
    }
    if (!brushWidth.isFinite || brushWidth <= 0 || brushWidth > 64) {
      throw ArgumentError.value(
        brushWidth,
        'brushWidth',
        'Expected 0 < width ≤ 64',
      );
    }
    _pointer = pointer;
    _active = DrawingStroke._(
      brushWidth == 1
          ? Offset(
              (point.dx.floorToDouble() + .5).clamp(.5, width - .5).toDouble(),
              (point.dy.floorToDouble() + .5).clamp(.5, height - .5).toDouble(),
            )
          : point,
      brushWidth,
    );
    notifyListeners();
    return true;
  }

  void extendStroke(int pointer, Offset point) {
    final active = _active;
    if (_pointer != pointer ||
        active == null ||
        _pointCount + active.points.length >= maxPoints ||
        !point.dx.isFinite ||
        !point.dy.isFinite) {
      return;
    }
    // Keep hostile/extreme pointer coordinates away from native path math.
    var x = point.dx.clamp(-width.toDouble(), width * 2.0).toDouble();
    var y = point.dy.clamp(-height.toDouble(), height * 2.0).toDouble();
    if (active.width == 1) {
      x = x.floorToDouble() + .5;
      y = y.floorToDouble() + .5;
    }
    final previous = active.points.last;
    final dx = x - previous.dx, dy = y - previous.dy;
    if (dx * dx + dy * dy < 0.0625) return;
    active._append(Offset(x, y));
    notifyListeners();
  }

  void endStroke(int pointer) {
    final active = _active;
    if (_pointer != pointer || active == null) return;
    _strokes.add(active);
    _pointCount += active.points.length;
    _active = null;
    _pointer = null;
    _clearUndo = null;
    notifyListeners();
  }

  void cancelStroke(int pointer) {
    if (_pointer != pointer || _active == null) return;
    _active = null;
    _pointer = null;
    notifyListeners();
  }

  void undo() {
    if (_active != null) {
      cancelStroke(_pointer!);
      return;
    }
    if (_strokes.isNotEmpty) {
      _pointCount -= _strokes.removeLast().points.length;
    } else if (_clearUndo != null) {
      _strokes.addAll(_clearUndo!);
      _clearUndo = null;
      _pointCount = _strokes.fold(
        0,
        (sum, stroke) => sum + stroke.points.length,
      );
    } else {
      return;
    }
    notifyListeners();
  }

  void clear() {
    _active = null;
    _pointer = null;
    if (_strokes.isNotEmpty) {
      _clearUndo = List.of(_strokes);
      _strokes.clear();
      _pointCount = 0;
    }
    notifyListeners();
  }

  void _paint(Canvas canvas, {bool includeActive = true}) {
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
    for (final line in _strokes) {
      _paintStroke(canvas, line);
    }
    if (includeActive && _active != null) _paintStroke(canvas, _active!);
    canvas.restore();
  }

  void _paintStroke(Canvas canvas, DrawingStroke line) {
    _brush
      ..strokeWidth = line.width
      ..isAntiAlias = line.width != 1;
    if (line.points.length == 1) {
      _brush.style = PaintingStyle.fill;
      canvas.drawCircle(line.points.first, line.width / 2, _brush);
    } else {
      _brush.style = PaintingStyle.stroke;
      canvas.drawPath(line._path, _brush);
    }
  }

  /// Captures only completed strokes. Export never includes the white UI paper.
  Future<Uint8List> exportPng() async {
    final recorder = ui.PictureRecorder();
    _paint(Canvas(recorder), includeActive: false);
    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(width, height);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('Не удалось сохранить рисунок');
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image?.dispose();
      picture.dispose();
    }
  }
}

class _DrawingEditor extends StatefulWidget {
  const _DrawingEditor({
    required this.width,
    required this.height,
    this.media,
    required this.rows,
    required this.columns,
    required this.trimMargins,
  });
  final int width, height;
  final MediaProfile? media;
  final int rows, columns;
  final bool trimMargins;

  @override
  State<_DrawingEditor> createState() => _DrawingEditorState();
}

class _DrawingEditorState extends State<_DrawingEditor> {
  late final DrawingDocument drawing;
  double brushWidth = 4;
  bool saving = false;
  String? error;

  @override
  void initState() {
    super.initState();
    drawing = DrawingDocument(
      width: widget.width,
      height: widget.height,
      media: widget.media,
      rows: widget.rows,
      columns: widget.columns,
      trimMargins: widget.trimMargins,
    );
  }

  @override
  void dispose() {
    drawing.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving || drawing.isBlank || drawing.isDrawing) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final png = await drawing.exportPng();
      if (mounted) Navigator.of(context).pop(png);
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = 'Не удалось сохранить рисунок. Попробуйте ещё раз.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000, maxHeight: 900),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: AnimatedBuilder(
              animation: drawing,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Рисунок',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Отменить последнее действие',
                        onPressed: !saving && drawing.canUndo
                            ? drawing.undo
                            : null,
                        icon: const Icon(Icons.undo),
                      ),
                      IconButton(
                        tooltip: 'Очистить рисунок',
                        onPressed:
                            !saving && (!drawing.isBlank || drawing.isDrawing)
                            ? drawing.clear
                            : null,
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                  Text(
                    '${widget.width} × ${widget.height} точек · чёрная кисть',
                  ),
                  if (widget.media != null)
                    const Text(
                      'Серые поля и скругления не печатаются. Скрытые штрихи сохраняются в исходнике.',
                    ),
                  Row(
                    children: [
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: ExcludeSemantics(
                          child: Center(
                            child: Container(
                              width: brushWidth,
                              height: brushWidth,
                              decoration: const BoxDecoration(
                                color: Colors.black,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: brushWidth,
                          min: 1,
                          max: 32,
                          divisions: 31,
                          label: '${brushWidth.round()} точек',
                          semanticFormatterCallback: (value) =>
                              '${value.round()} точек',
                          onChanged: saving || drawing.isDrawing
                              ? null
                              : (value) {
                                  setState(() => brushWidth = value);
                                },
                        ),
                      ),
                      SizedBox(
                        width: 72,
                        child: Text('${brushWidth.round()} точек'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final scale = math.min(
                              constraints.maxWidth / widget.width,
                              constraints.maxHeight / widget.height,
                            );
                            final paperSize = Size(
                              widget.width * scale,
                              widget.height * scale,
                            );
                            return Center(
                              child: _DrawingSurface(
                                drawing: drawing,
                                paperSize: paperSize,
                                brushWidth: brushWidth,
                                enabled: !saving,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    drawing.limitReached
                        ? 'Лимит рисунка: отмените штрих или очистите лист.'
                        : 'Рисуйте пальцем или мышью. Очистку можно отменить.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Отмена'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed:
                            saving || drawing.isBlank || drawing.isDrawing
                            ? null
                            : save,
                        child: Text(saving ? 'Сохранение…' : 'Сохранить'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _DrawingSurface extends StatefulWidget {
  const _DrawingSurface({
    required this.drawing,
    required this.paperSize,
    required this.brushWidth,
    required this.enabled,
  });
  final DrawingDocument drawing;
  final Size paperSize;
  final double brushWidth;
  final bool enabled;

  @override
  State<_DrawingSurface> createState() => _DrawingSurfaceState();
}

class _DrawingSurfaceState extends State<_DrawingSurface> {
  Size? strokeViewport;

  Offset point(PointerEvent event) => drawingPoint(
    event.localPosition,
    widget.paperSize,
    widget.drawing.width,
    widget.drawing.height,
  );

  bool sameViewport(int pointer) {
    if (strokeViewport == widget.paperSize) return true;
    widget.drawing.cancelStroke(pointer);
    return false;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Поле рисования',
    image: true,
    child: MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.precise
          : SystemMouseCursors.basic,
      child: RawGestureDetector(
        // Claim the paper gesture on down, before any enclosing scroll view.
        gestures: {
          EagerGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                EagerGestureRecognizer.new,
                (_) {},
              ),
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (!widget.enabled || event.buttons != kPrimaryButton) return;
            if (widget.drawing.beginStroke(
              event.pointer,
              point(event),
              widget.brushWidth,
            )) {
              strokeViewport = widget.paperSize;
            }
          },
          onPointerMove: (event) {
            if (widget.enabled && sameViewport(event.pointer)) {
              widget.drawing.extendStroke(event.pointer, point(event));
            }
          },
          onPointerUp: (event) {
            if (sameViewport(event.pointer)) {
              widget.drawing.extendStroke(event.pointer, point(event));
              widget.drawing.endStroke(event.pointer);
            }
          },
          onPointerCancel: (event) =>
              widget.drawing.cancelStroke(event.pointer),
          child: ClipRect(
            child: CustomPaint(
              key: const ValueKey('drawing-paper'),
              size: widget.paperSize,
              painter: _DrawingPainter(widget.drawing),
            ),
          ),
        ),
      ),
    ),
  );
}

class _DrawingPainter extends CustomPainter {
  _DrawingPainter(this.drawing) : super(repaint: drawing);
  final DrawingDocument drawing;
  static final Paint _paper = Paint()..color = const Color(0xffbdbdbd);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _paper);
    canvas.save();
    canvas.scale(size.width / drawing.width, size.height / drawing.height);
    drawing.paintPreview(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_DrawingPainter oldDelegate) =>
      drawing != oldDelegate.drawing;
}
