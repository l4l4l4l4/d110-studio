import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'label.dart';
import 'printer.dart';
import 'raster.dart';
import 'fonts.dart';
import 'image_picker.dart';
import 'sticker_stack.dart';
import 'printer_connection.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerFontLicenses();
  runApp(const StudioApp());
}

abstract final class StudioColors {
  static const bg = Color(0xff282828);
  static const surface = Color(0xff3c3836);
  static const border = Color(0xff504945);
  static const muted = Color(0xff928374);
  static const text = Color(0xffebdbb2);
  static const accent = Color(0xfffabd2f);
  static const green = Color(0xffb8bb26);
  static const red = Color(0xfffb4934);
  static const blue = Color(0xff83a598);
}

class StudioApp extends StatelessWidget {
  const StudioApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'D110 Studio',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'NotoSans',
      colorScheme: const ColorScheme.dark(
        primary: StudioColors.accent,
        onPrimary: StudioColors.bg,
        primaryContainer: StudioColors.border,
        onPrimaryContainer: StudioColors.accent,
        secondary: StudioColors.blue,
        onSecondary: StudioColors.bg,
        secondaryContainer: StudioColors.border,
        onSecondaryContainer: StudioColors.blue,
        tertiary: StudioColors.green,
        onTertiary: StudioColors.bg,
        tertiaryContainer: StudioColors.border,
        onTertiaryContainer: StudioColors.green,
        surface: StudioColors.surface,
        onSurface: StudioColors.text,
        onSurfaceVariant: StudioColors.muted,
        outline: StudioColors.border,
        outlineVariant: StudioColors.border,
        surfaceDim: StudioColors.bg,
        surfaceBright: StudioColors.surface,
        surfaceContainerLowest: StudioColors.bg,
        surfaceContainerLow: StudioColors.bg,
        surfaceContainer: StudioColors.surface,
        surfaceContainerHigh: StudioColors.surface,
        surfaceContainerHighest: StudioColors.surface,
        inverseSurface: StudioColors.text,
        onInverseSurface: StudioColors.bg,
        inversePrimary: StudioColors.bg,
        error: StudioColors.red,
        onError: StudioColors.bg,
        errorContainer: StudioColors.surface,
        onErrorContainer: StudioColors.red,
        surfaceTint: Colors.transparent,
      ),
      scaffoldBackgroundColor: StudioColors.bg,
      appBarTheme: const AppBarTheme(
        backgroundColor: StudioColors.bg,
        foregroundColor: StudioColors.text,
        surfaceTintColor: Colors.transparent,
      ),
      dividerColor: StudioColors.border,
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: StudioColors.surface,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: StudioColors.muted,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
    ),
    home: const StudioPage(),
  );
}

class StudioPage extends StatefulWidget {
  const StudioPage({super.key});
  @override
  State<StudioPage> createState() => _StudioPageState();
}

class _StudioPageState extends State<StudioPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final printer = PrinterClient();
  LabelDocument document = LabelDocument(
    elements: [
      LabelElement(
        kind: ElementKind.text,
        text: 'Моя этикетка',
        x: 16,
        y: 30,
        width: 205,
        height: 40,
      ),
    ],
  );
  LabelElement? selected;
  List<Map<String, dynamic>> templates = [];
  late final connection = PrinterConnectionController(printer);
  String? error;
  bool busy = false, preview = false;
  bool inspectorOpen = false, colorImages = false;
  ui.Image? previewImage;
  Timer? previewTimer;
  int previewVersion = 0;
  Offset? dragPoint;
  double startX = 0,
      startY = 0,
      startWidth = 0,
      startHeight = 0,
      startAngle = 0,
      startFont = 0,
      startTextScaleX = 1,
      startTextScaleY = 1;
  _DragHandle? activeHandle, pointerHandle;
  Offset? pointerDown;
  Rect? selectionBounds;
  double viewZoom = 1;
  Offset viewPan = Offset.zero;
  bool zoomingLabel = false;
  double startZoom = 1;
  Offset startPan = Offset.zero;
  Offset? zoomFocal;
  late final AnimationController ants = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..repeat();
  int revision = 0;
  bool get native => !kIsWeb;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    connection.addListener(_connectionChanged);
    selected = document.elements.first;
    if (native) unawaited(_loadTemplates());
    if (native) unawaited(connection.restore());
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (native && state == AppLifecycleState.resumed && !busy) {
      unawaited(connection.restore());
    }
  }

  Future<void> _loadTemplates() async {
    try {
      final saved = jsonDecode(await printer.loadTemplates()) as List;
      if (!mounted) return;
      setState(
        () => templates = saved
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
      );
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось загрузить шаблоны: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    connection.dispose();
    ants.dispose();
    previewTimer?.cancel();
    previewImage?.dispose();
    document.dispose();
    printer.dispose();
    super.dispose();
  }

  void changed() {
    setState(() => error = null);
    revision++;
    if (preview) refreshPreview();
  }

  void refreshPreview() {
    final version = ++previewVersion;
    previewTimer?.cancel();
    previewTimer = Timer(const Duration(milliseconds: 80), () async {
      try {
        final next = await renderDesign(document);
        if (!mounted || version != previewVersion) {
          next.dispose();
          return;
        }
        setState(() {
          previewImage?.dispose();
          previewImage = next;
        });
      } catch (e) {
        if (mounted) setState(() => error = '$e');
      }
    });
  }

  Future<void> action(Future<void> Function() operation) async {
    if (busy || connection.busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> askText(String title, String initial) {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          maxLines: 3,
          onChanged: (text) => value = text,
          onFieldSubmitted: (text) => Navigator.pop(context, text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, value),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  Future<void> add(ElementKind kind) => action(() async {
    if (document.elements.length >= 100) {
      throw StateError('На этикетке уже 100 элементов');
    }
    final element = LabelElement(kind: kind);
    if (kind == ElementKind.image) {
      final bytes = await pickStudioImage(printer);
      if (bytes == null) return;
      if (bytes.length > 16 * 1024 * 1024) {
        throw const FormatException('Изображение должно быть не больше 16 МиБ');
      }
      element.imageBytes = bytes;
      try {
        await element.prepare();
      } catch (_) {
        element.dispose();
        rethrow;
      }
      // Source dimensions precede downsampling, including very thin images.
      final sourceWidth = element.imageSourceWidth;
      final sourceHeight = element.imageSourceHeight;
      final factor = 88 / math.max(sourceWidth, sourceHeight);
      element.width = sourceWidth * factor;
      element.height = sourceHeight * factor;
      element.x = 4;
      element.y = 4;
    } else {
      final value = await askText(
        kind == ElementKind.qr ? 'Содержимое QR' : 'Текст',
        kind == ElementKind.qr ? 'https://example.com' : 'Новый текст',
      );
      if (value == null || value.isEmpty || !mounted) return;
      element.text = value;
      if (kind == ElementKind.qr) {
        element.width = 88;
        element.height = 88;
        element.x = 4;
        element.y = 4;
      }
    }
    try {
      if (kind != ElementKind.image) await element.prepare();
    } catch (_) {
      element.dispose();
      rethrow;
    }
    if (!mounted) {
      element.dispose();
      return;
    }
    document.elements.add(element);
    selected = element;
    preview = false;
    changed();
  });
  Future<void> connect() => action(() async {
    if (connection.phase == PrinterConnectionPhase.permissionRequired) {
      await connection.enableAndReconnect();
      if (!mounted ||
          connection.phase != PrinterConnectionPhase.selectPrinter) {
        return;
      }
    }
    Future<void> discoveryFinished = Future.value();
    Future<List<PrinterDevice>> discover() {
      final request = connection.discover();
      // The dialog displays search errors; cancellation still waits for the
      // native request to release the client's single-flight lock.
      discoveryFinished = request.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {},
      );
      return request;
    }

    final address = await showDialog<String>(
      context: context,
      builder: (context) => DeviceDialog(discover: discover),
    );
    await discoveryFinished;
    if (address == null || !mounted) return;
    await connection.connect(address);
  });
  int density = 2;
  Future<void> print() => action(() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (document.elements.isEmpty) {
      throw StateError('Добавьте текст, QR или изображение');
    }
    for (final element in document.elements) {
      if (element.kind == ElementKind.qr || element.kind == ElementKind.image) {
        await element.prepare();
      }
    }
    if (!mounted) return;
    final warnings = printWarnings(document);
    if (warnings.isNotEmpty) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Проверьте макет'),
          content: Text(warnings.join('\n\n')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Исправить'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Печатать как есть'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }
    if (!mounted) return;
    if (document.tileCount > 1) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => StickerPrintDialog(
          document: document,
          printTile: (index) async {
            if (!printer.connected) {
              throw StateError(
                'Принтер отключён. Эта сборка остановлена без повторной печати.',
              );
            }
            final raster = await renderTile(document, index);
            await printer.printRaster(
              raster.packed,
              raster.height,
              density: density,
            );
          },
        ),
      );
      return;
    }
    final raster = await renderLabel(document);
    await printer.printRaster(raster.packed, raster.height, density: density);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Принтер подтвердил завершение задания. Проверьте этикетку.',
        ),
      ),
    );
  });
  Future<void> save() => action(() async {
    final name = await askText('Название шаблона', document.name);
    if (name == null || name.trim().isEmpty || !mounted) return;
    document.name = name.trim();
    final saved = document.toJson();
    final next = templates.where((e) => e['name'] != document.name).toList()
      ..add(saved);
    await printer.saveTemplates(jsonEncode(next));
    if (mounted) setState(() => templates = next);
  });
  Future<void> open() => action(() async {
    final saved = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Шаблоны'),
        children: templates.isEmpty
            ? [
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Сохранённых шаблонов пока нет'),
                ),
              ]
            : templates
                  .map(
                    (e) => SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, e),
                      child: Text(e['name'] as String),
                    ),
                  )
                  .toList(),
      ),
    );
    if (saved == null || !mounted) return;
    final next = LabelDocument.fromJson(saved);
    try {
      for (final element in next.elements) {
        await element.prepare();
      }
    } catch (_) {
      next.dispose();
      rethrow;
    }
    if (!mounted) {
      next.dispose();
      return;
    }
    document.dispose();
    document = next;
    selected = next.elements.firstOrNull;
    changed();
  });
  void mutateSelected(void Function(LabelElement) mutation) {
    if (busy || preview || selected == null) return;
    mutation(selected!);
    changed();
  }

  Future<void> prepareElement(LabelElement element) async {
    try {
      await element.prepare();
      if (mounted && document.elements.contains(element)) changed();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void deleteSelected() {
    final element = selected;
    if (element == null || busy) return;
    document.elements.remove(element);
    element.dispose();
    selected = null;
    inspectorOpen = false;
    changed();
  }

  Future<void> sheet(String title, Widget Function(BuildContext) content) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        constraints: const BoxConstraints(maxWidth: 620),
        builder: (context) => SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .7,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    content(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  void editSelected() {
    if (selected == null || busy) return;
    setState(() {
      preview = false;
      inspectorOpen = true;
    });
  }

  Widget editorWorkspace() => LayoutBuilder(
    builder: (context, constraints) {
      final element = selected;
      if (!inspectorOpen || element == null) return canvas();
      final inspector = Container(
        key: const ValueKey('live-inspector'),
        decoration: const BoxDecoration(
          color: StudioColors.surface,
          border: Border(
            left: BorderSide(color: StudioColors.border),
            top: BorderSide(color: StudioColors.border),
          ),
        ),
        child: Column(
          children: [
            Row(
              children: [
                const SizedBox(width: 16),
                Icon(elementIcon(element), color: StudioColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    elementName(element),
                    style: const TextStyle(color: StudioColors.accent),
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть настройки',
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    setState(() => inspectorOpen = false);
                  },
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                child: Column(
                  children: [
                    if (element.kind == ElementKind.image) ...[
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('Ч/б · печать'),
                          ),
                          ButtonSegment(value: true, label: Text('Оригинал')),
                        ],
                        selected: {colorImages},
                        onSelectionChanged: (value) =>
                            setState(() => colorImages = value.single),
                      ),
                      const SizedBox(height: 12),
                    ],
                    ElementPanel(
                      key: ObjectKey(element),
                      element: element,
                      enabled: !busy && !preview,
                      onChanged: changed,
                      onImageChanged: () => unawaited(prepareElement(element)),
                      onDelete: deleteSelected,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
      if (constraints.maxWidth >= 850) {
        return Row(
          children: [
            Expanded(child: canvas()),
            SizedBox(width: 360, child: inspector),
          ],
        );
      }
      return Column(
        children: [
          Expanded(child: canvas()),
          SizedBox(
            height: math.min(340, constraints.maxHeight * .5),
            child: inspector,
          ),
        ],
      );
    },
  );

  void labelSettings() => unawaited(
    sheet(
      'Этикетка и принтер',
      (context) => StatefulBuilder(
        builder: (context, update) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Одна наклейка: ${document.lengthMm} × 12 мм / '
              '${document.tileWidth} × 96 точек.\n'
              'Зазор 8 мм обрабатывает принтер — он не входит в макет.',
            ),
            const SizedBox(height: 16),
            NumberControl(
              label: 'Длина',
              value: document.lengthMm.toDouble(),
              min: 10,
              max: 150,
              suffix: 'мм',
              onChanged: busy
                  ? null
                  : (value) {
                      document.lengthMm = value.round();
                      changed();
                      update(() {});
                    },
            ),
            const Divider(height: 24),
            const Text('Сборка из наклеек · единый макет'),
            NumberControl(
              label: 'Столбцы',
              value: document.columns.toDouble(),
              min: 1,
              max: 8,
              onChanged: busy
                  ? null
                  : (value) {
                      document.columns = value.round();
                      viewZoom = 1;
                      viewPan = Offset.zero;
                      changed();
                      update(() {});
                    },
            ),
            NumberControl(
              label: 'Строки',
              value: document.rows.toDouble(),
              min: 1,
              max: 8,
              onChanged: busy
                  ? null
                  : (value) {
                      document.rows = value.round();
                      viewZoom = 1;
                      viewPan = Offset.zero;
                      changed();
                      update(() {});
                    },
            ),
            Text(
              '${document.tileCount} наклеек · '
              '${document.lengthMm * document.columns} × '
              '${12 * document.rows} мм.\n'
              'Печать по строкам слева направо. Между наклейками '
              'нужно подтвердить размещение; швы на макете не печатаются.',
              style: const TextStyle(color: StudioColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: busy
                  ? null
                  : () {
                      document.rotateHalfTurn();
                      changed();
                    },
              icon: const Icon(Icons.rotate_right),
              label: const Text('Повернуть всю этикетку на 180°'),
            ),
            const Divider(height: 32),
            Text(
              native
                  ? connection.message
                  : 'Bluetooth и печать — только в приложении.',
              style: const TextStyle(color: StudioColors.blue),
            ),
            const SizedBox(height: 12),
            const Text('Нагрев · 3 — максимум'),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('1')),
                ButtonSegment(value: 1, label: Text('2')),
                ButtonSegment(value: 2, label: Text('3')),
              ],
              selected: {density},
              onSelectionChanged: busy
                  ? null
                  : (value) {
                      setState(() => density = value.single);
                      update(() {});
                    },
            ),
            if (!native) ...[
              const SizedBox(height: 12),
              const Text(
                'В браузере работают изображения, текст и QR. '
                'Шаблоны сохраняются локально в нативном приложении.',
              ),
            ],
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'D110 Studio',
                applicationVersion: '1.0.0',
              ),
              icon: const Icon(Icons.info_outline),
              label: const Text('Лицензии приложения и шрифтов'),
            ),
          ],
        ),
      ),
    ),
  );

  void showObjects() => unawaited(
    sheet(
      'Объекты',
      (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (document.elements.isEmpty)
            const Text('Добавьте текст, QR или изображение'),
          for (final entry in document.elements.asMap().entries)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(elementIcon(entry.value)),
              title: Text('${entry.key + 1}. ${elementName(entry.value)}'),
              subtitle: entry.value.kind == ElementKind.image
                  ? null
                  : Text(
                      entry.value.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              selected: selected == entry.value,
              selectedColor: StudioColors.accent,
              trailing: selected == entry.value
                  ? const Icon(Icons.check)
                  : null,
              onTap: busy
                  ? null
                  : () {
                      setState(() {
                        selected = entry.value;
                        preview = false;
                      });
                      Navigator.pop(context);
                    },
            ),
        ],
      ),
    ),
  );

  Widget canvas() => LayoutBuilder(
    builder: (context, constraints) {
      final portrait =
          constraints.maxWidth < 600 &&
          constraints.maxHeight > constraints.maxWidth * .9;
      final side = math.max(
        document.width.toDouble(),
        document.canvasHeight.toDouble(),
      );
      final fit = math
          .min(
            (constraints.maxWidth - 48) / side,
            (constraints.maxHeight - 48) / side,
          )
          .clamp(.05, 12.0);
      final scale = fit * viewZoom;
      // The gesture surface is the entire viewport, not the paper-sized square.
      // A resized/rotated object's knobs can lie outside the physical label.
      final viewportWidth = portrait
          ? constraints.maxHeight
          : constraints.maxWidth;
      final viewportHeight = portrait
          ? constraints.maxWidth
          : constraints.maxHeight;
      final inset = Offset(
        (viewportWidth - document.width * scale) / 2,
        (viewportHeight - document.canvasHeight * scale) / 2,
      );
      Offset labelPoint(Offset local) => (local - inset) / scale;
      final pan = portrait ? Offset(viewPan.dy, -viewPan.dx) : viewPan;
      final margin = math.min(
        16.0,
        math.min(viewportWidth, viewportHeight) / 2,
      );
      selectionBounds = Rect.fromPoints(
        labelPoint(Offset(margin, margin) - pan),
        labelPoint(
          Offset(viewportWidth - margin, viewportHeight - margin) - pan,
        ),
      );
      return ClipRect(
        child: Center(
          child: Transform.translate(
            offset: viewPan,
            child: RotatedBox(
              quarterTurns: portrait ? 1 : 0,
              child: SizedBox(
                width: viewportWidth,
                height: viewportHeight,
                child: Listener(
                  key: const ValueKey('label-gesture'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: preview || busy
                      ? null
                      : (event) {
                          final point = labelPoint(event.localPosition);
                          pointerHandle = hitHandle(point, scale);
                          pointerDown = pointerHandle != null ? point : null;
                        },
                  onPointerUp: (_) => pointerDown = null,
                  onPointerCancel: (_) => pointerDown = null,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: preview || busy
                        ? null
                        : (details) {
                            final point = labelPoint(details.localPosition);
                            if (hitHandle(point, scale) != null) return;
                            setState(
                              () => selected = document.elements.reversed
                                  .where((element) => element.contains(point))
                                  .firstOrNull,
                            );
                          },
                    onScaleStart: preview || busy
                        ? null
                        : (details) {
                            if (details.pointerCount >= 2) {
                              zoomingLabel = true;
                              startZoom = viewZoom;
                              startPan = viewPan;
                              zoomFocal = details.localFocalPoint;
                              return;
                            }
                            final point =
                                details.pointerCount == 1 && pointerDown != null
                                ? pointerDown!
                                : labelPoint(details.localFocalPoint);
                            activeHandle = details.pointerCount == 1
                                ? pointerHandle
                                : null;
                            if (activeHandle == null &&
                                (details.pointerCount < 2 ||
                                    selected == null)) {
                              selected = document.elements.reversed
                                  .where((element) => element.contains(point))
                                  .firstOrNull;
                            }
                            dragPoint = point;
                            if (selected case final element?) {
                              startX = element.x;
                              startY = element.y;
                              startWidth = element.width;
                              startHeight = element.height;
                              startAngle = element.rotation;
                              startFont = element.fontSize;
                              startTextScaleX = element.textScaleX;
                              startTextScaleY = element.textScaleY;
                            }
                            setState(() {});
                          },
                    onScaleUpdate: preview || busy
                        ? null
                        : (details) {
                            if (zoomingLabel) {
                              final focal = zoomFocal;
                              if (focal == null) return;
                              setState(() {
                                viewZoom = (startZoom * details.scale).clamp(
                                  .4,
                                  6,
                                );
                                viewPan =
                                    startPan + details.localFocalPoint - focal;
                              });
                              return;
                            }
                            final element = selected, origin = dragPoint;
                            if (element == null || origin == null) return;
                            final current = labelPoint(details.localFocalPoint);
                            final delta = current - origin;
                            element.width = startWidth;
                            element.height = startHeight;
                            element.fontSize = startFont;
                            element.textScaleX = startTextScaleX;
                            element.textScaleY = startTextScaleY;
                            element.x = startX;
                            element.y = startY;
                            if (activeHandle != null) {
                              final center = Offset(
                                startX + startWidth / 2,
                                startY + startHeight / 2,
                              );
                              final before = origin - center;
                              final after = current - center;
                              if (activeHandle == _DragHandle.rotate) {
                                element.rotation =
                                    startAngle +
                                    math.atan2(after.dy, after.dx) -
                                    math.atan2(before.dy, before.dx);
                              } else {
                                final c = math.cos(startAngle);
                                final s = math.sin(startAngle);
                                final dx = delta.dx * c + delta.dy * s;
                                final dy = -delta.dx * s + delta.dy * c;
                                final horizontal = 1 + 2 * dx / startWidth;
                                final vertical = 1 + 2 * dy / startHeight;
                                final shared =
                                    1 +
                                    2 *
                                        (dx * startWidth + dy * startHeight) /
                                        (startWidth * startWidth +
                                            startHeight * startHeight);
                                scaleElement(
                                  element,
                                  element.aspectLocked ? shared : horizontal,
                                  element.aspectLocked ? shared : vertical,
                                );
                              }
                              changed();
                              return;
                            }
                            scaleElement(
                              element,
                              element.aspectLocked
                                  ? details.scale
                                  : details.horizontalScale,
                              element.aspectLocked
                                  ? details.scale
                                  : details.verticalScale,
                            );
                            element.x += delta.dx;
                            element.y += delta.dy;
                            element.rotation = startAngle + details.rotation;
                            changed();
                          },
                    onScaleEnd: (_) {
                      zoomingLabel = false;
                      activeHandle = pointerHandle = null;
                    },
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: inset.dx,
                          top: inset.dy,
                          width: document.width * scale,
                          height: document.canvasHeight * scale,
                          child: Stack(
                            clipBehavior: Clip.none,
                            fit: StackFit.expand,
                            children: [
                              RepaintBoundary(
                                child: CustomPaint(
                                  painter: LabelPainter(
                                    document,
                                    scale,
                                    preview ? previewImage : null,
                                    revision,
                                    colorImages,
                                  ),
                                ),
                              ),
                              if (!preview && selected != null)
                                IgnorePointer(
                                  child: RepaintBoundary(
                                    child: CustomPaint(
                                      painter: SelectionPainter(
                                        selected!,
                                        scale,
                                        ants,
                                        revision,
                                        bounds: selectionBounds,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  _DragHandle? hitHandle(Offset point, double scale) {
    final element = selected;
    if (element == null) return null;
    final knobs = _selectionKnobs(element, selectionBounds);
    final radiusSquared = 22 * 22 / (scale * scale);
    final rotateDistance = (point - knobs.rotate).distanceSquared;
    final resizeDistance = (point - knobs.resize).distanceSquared;
    // Small objects have overlapping 44px targets: use the closest knob,
    // rather than letting the rotation target swallow the resize target.
    if (math.min(rotateDistance, resizeDistance) <= radiusSquared) {
      return resizeDistance < rotateDistance
          ? _DragHandle.resize
          : _DragHandle.rotate;
    }
    return null;
  }

  Widget tool(IconData icon, String label, VoidCallback? onPressed) => SizedBox(
    width: 68,
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 10),
        foregroundColor: StudioColors.text,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 23),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final element = selected;
    final editable = !busy && !preview && element != null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('D110 Studio', style: TextStyle(fontSize: 20)),
        actions: [
          IconButton(
            tooltip: native
                ? 'Открыть локальный шаблон'
                : 'Шаблоны — в приложении',
            onPressed: native && !busy ? open : null,
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: native
                ? 'Сохранить локальный шаблон'
                : 'Шаблоны — в приложении',
            onPressed: native && !busy ? save : null,
            icon: const Icon(Icons.save_outlined),
          ),
          IconButton(
            tooltip: preview
                ? 'Вернуться к редактированию'
                : 'Точное ч/б-превью',
            isSelected: preview,
            selectedIcon: const Icon(
              Icons.visibility,
              color: StudioColors.accent,
            ),
            onPressed: busy
                ? null
                : () {
                    setState(() => preview = !preview);
                    if (preview) refreshPreview();
                  },
            icon: const Icon(Icons.visibility_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              children: [
                if (busy || connection.busy)
                  const LinearProgressIndicator(minHeight: 2),
                if (error != null)
                  Container(
                    color: StudioColors.surface,
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: StudioColors.red,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            error!,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: StudioColors.red),
                          ),
                        ),
                        IconButton(
                          onPressed: () => setState(() => error = null),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                Expanded(child: editorWorkspace()),
                Container(
                  decoration: const BoxDecoration(
                    color: StudioColors.surface,
                    border: Border(top: BorderSide(color: StudioColors.border)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                        child: Row(
                          children: [
                            Icon(
                              element == null
                                  ? Icons.touch_app_outlined
                                  : elementIcon(element),
                              color: StudioColors.accent,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                element == null
                                    ? 'Выберите объект на этикетке'
                                    : '${elementName(element)} · '
                                          '${formatDimension(element.width)} × '
                                          '${formatDimension(element.height)} т.',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: StudioColors.accent,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Удалить выбранный объект',
                              onPressed: editable ? deleteSelected : null,
                              icon: const Icon(
                                Icons.delete_outline,
                                color: StudioColors.red,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            tooltip: 'Повернуть на −90°',
                            onPressed: editable
                                ? () => mutateSelected(
                                    (e) => e.rotation -= math.pi / 2,
                                  )
                                : null,
                            icon: const Icon(Icons.rotate_left),
                          ),
                          IconButton(
                            tooltip: 'Повернуть на +90°',
                            onPressed: editable
                                ? () => mutateSelected(
                                    (e) => e.rotation += math.pi / 2,
                                  )
                                : null,
                            icon: const Icon(Icons.rotate_right),
                          ),
                          IconButton(
                            tooltip: 'Уменьшить на 10%',
                            onPressed: editable
                                ? () => mutateSelected(
                                    (e) => scaleElement(e, 1 / 1.1, 1 / 1.1),
                                  )
                                : null,
                            icon: const Icon(Icons.zoom_out),
                          ),
                          IconButton(
                            tooltip: 'Увеличить на 10%',
                            onPressed: editable
                                ? () => mutateSelected(
                                    (e) => scaleElement(e, 1.1, 1.1),
                                  )
                                : null,
                            icon: const Icon(Icons.zoom_in),
                          ),
                          IconButton(
                            tooltip: element?.aspectLocked == false
                                ? 'Свободные пропорции · заблокировать'
                                : 'Пропорции сохранены · разблокировать',
                            onPressed: editable
                                ? () => mutateSelected(
                                    (e) => e.aspectLocked = !e.aspectLocked,
                                  )
                                : null,
                            icon: Icon(
                              element?.aspectLocked == false
                                  ? Icons.lock_open
                                  : Icons.lock_outline,
                              color: element?.aspectLocked == true
                                  ? StudioColors.accent
                                  : null,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Размеры и настройки объекта',
                            onPressed: editable ? editSelected : null,
                            icon: const Icon(Icons.tune),
                          ),
                        ],
                      ),
                      const Divider(height: 1),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            tool(
                              Icons.text_fields,
                              'Текст',
                              busy ? null : () => add(ElementKind.text),
                            ),
                            tool(
                              Icons.qr_code,
                              'QR',
                              busy ? null : () => add(ElementKind.qr),
                            ),
                            tool(
                              Icons.add_photo_alternate_outlined,
                              'Фото',
                              busy ? null : () => add(ElementKind.image),
                            ),
                            tool(
                              Icons.edit_outlined,
                              'Правка',
                              editable ? editSelected : null,
                            ),
                            tool(
                              Icons.layers_outlined,
                              'Объекты',
                              busy ? null : showObjects,
                            ),
                            tool(
                              Icons.straighten,
                              'Этикетка',
                              busy ? null : labelSettings,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (native)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                    child: Text(
                      connection.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: StudioColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: native && !busy && !connection.busy
                              ? (printer.connected
                                    ? () => action(printer.disconnect)
                                    : (connection.phase ==
                                              PrinterConnectionPhase
                                                  .bluetoothOff ||
                                          connection.phase ==
                                              PrinterConnectionPhase
                                                  .enableDeclined ||
                                          connection.phase ==
                                              PrinterConnectionPhase
                                                  .awaitingSettings)
                                    ? () =>
                                          action(connection.enableAndReconnect)
                                    : connect)
                              : null,
                          icon: Icon(
                            Icons.bluetooth,
                            color: printer.connected
                                ? StudioColors.green
                                : null,
                          ),
                          label: Text(
                            !native
                                ? 'В приложении'
                                : printer.connected
                                ? 'Отключить'
                                : (connection.phase ==
                                          PrinterConnectionPhase.bluetoothOff ||
                                      connection.phase ==
                                          PrinterConnectionPhase
                                              .enableDeclined ||
                                      connection.phase ==
                                          PrinterConnectionPhase
                                              .awaitingSettings)
                                ? 'Включить Bluetooth'
                                : 'Подключить',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              native &&
                                  printer.connected &&
                                  !busy &&
                                  !connection.busy
                              ? print
                              : null,
                          icon: const Icon(Icons.print_outlined),
                          label: const Text('Печатать'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _DragHandle { rotate, resize }

String elementName(LabelElement element) => switch (element.kind) {
  ElementKind.text => 'Текст',
  ElementKind.qr => 'QR-код',
  ElementKind.image => 'Изображение',
};

IconData elementIcon(LabelElement element) => switch (element.kind) {
  ElementKind.text => Icons.text_fields,
  ElementKind.qr => Icons.qr_code,
  ElementKind.image => Icons.image_outlined,
};

// Clamp resize factors before applying them so box and glyph geometry agree.
void scaleElement(LabelElement element, double horizontal, double vertical) {
  var x = horizontal.isFinite ? horizontal : 1.0;
  var y = vertical.isFinite ? vertical : 1.0;
  final isText = element.kind == ElementKind.text;
  final stretch = isText && element.textResizeMode == TextResizeMode.stretch;
  var minX = math.min(1.0, .000001 / element.width);
  var minY = math.min(1.0, .000001 / element.height);
  var maxX = LabelDocument.maxElementWidth / element.width;
  var maxY = 2400 / element.height;
  if (stretch) {
    minX = math.max(minX, minTextScale / element.textScaleX);
    minY = math.max(minY, minTextScale / element.textScaleY);
    maxX = math.min(maxX, maxTextScale / element.textScaleX);
    maxY = math.min(maxY, maxTextScale / element.textScaleY);
  }
  if (element.aspectLocked) {
    var minFactor = math.max(minX, minY);
    var maxFactor = math.min(maxX, maxY);
    if (isText && !stretch) {
      minFactor = math.max(minFactor, 1 / element.fontSize);
      maxFactor = math.min(maxFactor, 300 / element.fontSize);
    }
    x = x.clamp(minFactor, maxFactor);
    y = x;
  } else {
    x = x.clamp(minX, maxX);
    y = y.clamp(minY, maxY);
  }
  final width = element.width * x, height = element.height * y;
  element.x -= (width - element.width) / 2;
  element.y -= (height - element.height) / 2;
  element.width = width;
  element.height = height;
  if (stretch) {
    element.textScaleX = (element.textScaleX * x).clamp(
      minTextScale,
      maxTextScale,
    );
    element.textScaleY = (element.textScaleY * y).clamp(
      minTextScale,
      maxTextScale,
    );
  } else if (isText && element.aspectLocked) {
    element.fontSize = (element.fontSize * x).clamp(1.0, 300.0);
  }
}

String formatDimension(double value) =>
    value >= 1 ? value.toStringAsFixed(0) : value.toStringAsPrecision(3);

class LabelPainter extends CustomPainter {
  LabelPainter(
    this.document,
    this.scale,
    this.preview,
    this.revision, [
    this.colorImages = false,
  ]);
  final bool colorImages;
  final LabelDocument document;
  final double scale;
  final ui.Image? preview;
  final int revision;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(scale);
    if (preview != null) {
      canvas.drawImage(
        preview!,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.none,
      );
    } else {
      paintLabel(canvas, document, colorImages: colorImages);
    }
    paintTileSeams(canvas, document, scale);
  }

  @override
  bool shouldRepaint(covariant LabelPainter oldDelegate) =>
      oldDelegate.revision != revision ||
      oldDelegate.scale != scale ||
      oldDelegate.preview != preview ||
      oldDelegate.document != document ||
      oldDelegate.colorImages != colorImages;
}

({Offset rotate, Offset resize}) _selectionKnobs(
  LabelElement element,
  Rect? bounds,
) {
  final center = Offset(
    element.x + element.width / 2,
    element.y + element.height / 2,
  );
  final c = math.cos(element.rotation), s = math.sin(element.rotation);
  final half = Offset(
    element.width / 2 * c - element.height / 2 * s,
    element.width / 2 * s + element.height / 2 * c,
  );
  Offset visible(Offset point) => bounds == null
      ? point
      : Offset(
          point.dx.clamp(bounds.left, bounds.right),
          point.dy.clamp(bounds.top, bounds.bottom),
        );
  return (rotate: visible(center - half), resize: visible(center + half));
}

void paintTileSeams(Canvas canvas, LabelDocument document, double scale) {
  if (document.tileCount == 1) return;
  final seam = Paint()
    ..color = StudioColors.blue
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1 / scale;
  for (var column = 1; column < document.columns; column++) {
    final x = (column * document.tileWidth).toDouble();
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, document.canvasHeight.toDouble()),
      seam,
    );
  }
  for (var row = 1; row < document.rows; row++) {
    final y = (row * LabelDocument.height).toDouble();
    canvas.drawLine(Offset(0, y), Offset(document.width.toDouble(), y), seam);
  }
}

class SelectionPainter extends CustomPainter {
  SelectionPainter(
    this.element,
    this.scale,
    this.animation,
    this.revision, {
    this.bounds,
  }) : super(repaint: animation) {
    final width = element.width * scale, height = element.height * scale;
    final x = width / 2, y = height / 2;
    path = Path()..addRect(Rect.fromLTRB(-x, -y, x, y));
    horizontal = Path();
    vertical = Path();
    for (var offset = -x - 12; offset < x + 12; offset += 12) {
      horizontal
        ..moveTo(offset, 0)
        ..lineTo(offset + 6, 0);
    }
    for (var offset = -y - 12; offset < y + 12; offset += 12) {
      vertical
        ..moveTo(0, offset)
        ..lineTo(0, offset + 6);
    }
    top = Rect.fromLTWH(-x - 1, -y - 1, width + 2, 2);
    bottom = Rect.fromLTWH(-x - 1, y - 1, width + 2, 2);
    left = Rect.fromLTWH(-x - 1, -y - 1, 2, height + 2);
    right = Rect.fromLTWH(x - 1, -y - 1, 2, height + 2);
    rotateKnob = Offset(-x, -y);
    resizeKnob = Offset(x, y);
    rotateSymbol = Path()
      ..addArc(
        Rect.fromCircle(center: Offset.zero, radius: 5),
        -math.pi / 4,
        math.pi * 1.5,
      )
      ..moveTo(4, 1)
      ..lineTo(4, -4)
      ..lineTo(-1, -4);
    resizeSymbol = Path()
      ..moveTo(-4, -4)
      ..lineTo(4, 4)
      ..moveTo(4, -1)
      ..lineTo(4, 4)
      ..lineTo(-1, 4);
  }
  final LabelElement element;
  final double scale;
  final Animation<double> animation;
  final int revision;
  final Rect? bounds;
  late final Path path, horizontal, vertical, rotateSymbol, resizeSymbol;
  late final Rect top, bottom, left, right;
  late final Offset rotateKnob, resizeKnob;
  final white = Paint()
    ..color = Colors.white
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  final black = Paint()
    ..color = Colors.black
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  final knobFill = Paint()..color = StudioColors.accent;

  void edge(Canvas canvas, Rect clip, Path pattern, double x, double y) {
    canvas.save();
    canvas.clipRect(clip, doAntiAlias: false);
    canvas.translate(x, y);
    canvas.drawPath(pattern, black);
    canvas.restore();
  }

  void knob(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 12, black);
    canvas.drawCircle(center, 10, knobFill);
    canvas.drawCircle(center, 10, white);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(
      (element.x + element.width / 2) * scale,
      (element.y + element.height / 2) * scale,
    );
    canvas.rotate(element.rotation);
    canvas.drawPath(path, white);
    final phase = animation.value * 12;
    edge(canvas, top, horizontal, phase, rotateKnob.dy);
    edge(canvas, right, vertical, resizeKnob.dx, phase);
    edge(canvas, bottom, horizontal, -phase, resizeKnob.dy);
    edge(canvas, left, vertical, rotateKnob.dx, -phase);
    canvas.restore();
    final positions = _selectionKnobs(element, bounds);
    void paintKnob(Offset position, Path symbol) {
      canvas.save();
      canvas.translate(position.dx * scale, position.dy * scale);
      canvas.rotate(element.rotation);
      knob(canvas, Offset.zero);
      canvas.drawPath(symbol, black);
      canvas.restore();
    }

    paintKnob(positions.rotate, rotateSymbol);
    paintKnob(positions.resize, resizeSymbol);
  }

  @override
  bool shouldRepaint(covariant SelectionPainter oldDelegate) =>
      oldDelegate.element != element ||
      oldDelegate.scale != scale ||
      oldDelegate.bounds != bounds ||
      oldDelegate.revision != revision;
}

class NumberControl extends StatefulWidget {
  const NumberControl({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.step = 1,
    this.suffix = '',
    super.key,
  });
  final String label, suffix;
  final double value, min, max, step;
  final ValueChanged<double>? onChanged;
  @override
  State<NumberControl> createState() => _NumberControlState();
}

class _NumberControlState extends State<NumberControl> {
  late final controller = TextEditingController(text: displayValue);
  final focus = FocusNode();
  String get displayValue => widget.value.abs() > 0 && widget.value.abs() < 1
      ? widget.value.toStringAsPrecision(3)
      : widget.value == widget.value.roundToDouble()
      ? widget.value.toStringAsFixed(0)
      : widget.value.toStringAsFixed(1);
  @override
  void didUpdateWidget(covariant NumberControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !focus.hasFocus) {
      controller.text = displayValue;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    super.dispose();
  }

  void submit(String text) {
    final value = double.tryParse(text.replaceAll(',', '.'));
    if (value == null || !value.isFinite) {
      controller.text = displayValue;
      return;
    }
    widget.onChanged?.call(value.clamp(widget.min, widget.max));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.text = displayValue;
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(child: Text(widget.label)),
        IconButton(
          tooltip: '${widget.label}: уменьшить',
          onPressed: widget.onChanged == null || widget.value <= widget.min
              ? null
              : () => widget.onChanged!(
                  (widget.value - widget.step).clamp(widget.min, widget.max),
                ),
          icon: const Icon(Icons.remove),
        ),
        SizedBox(
          width: 96,
          child: TextField(
            controller: controller,
            focusNode: focus,
            enabled: widget.onChanged != null,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(
              decimal: true,
              signed: true,
            ),
            decoration: InputDecoration(
              suffixText: widget.suffix.isEmpty ? null : widget.suffix,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 12,
              ),
            ),
            onChanged: (text) {
              final value = double.tryParse(text.replaceAll(',', '.'));
              if (value != null &&
                  value.isFinite &&
                  value >= widget.min &&
                  value <= widget.max) {
                widget.onChanged?.call(value);
              }
            },
            onSubmitted: submit,
            onTapOutside: (_) {
              submit(controller.text);
              FocusManager.instance.primaryFocus?.unfocus();
            },
          ),
        ),
        IconButton(
          tooltip: '${widget.label}: увеличить',
          onPressed: widget.onChanged == null || widget.value >= widget.max
              ? null
              : () => widget.onChanged!(
                  (widget.value + widget.step).clamp(widget.min, widget.max),
                ),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
  );
}

class ElementPanel extends StatefulWidget {
  const ElementPanel({
    required this.element,
    required this.enabled,
    required this.onChanged,
    required this.onImageChanged,
    required this.onDelete,
    super.key,
  });
  final LabelElement element;
  final bool enabled;
  final VoidCallback onChanged, onImageChanged, onDelete;
  @override
  State<ElementPanel> createState() => _ElementPanelState();
}

class _ElementPanelState extends State<ElementPanel> {
  late final text = TextEditingController(text: widget.element.text);
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void update(VoidCallback mutation, {bool image = false}) {
    setState(mutation);
    widget.onChanged();
    if (image) widget.onImageChanged();
  }

  Widget control(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> change, {
    double step = 1,
    String suffix = '',
  }) => NumberControl(
    label: label,
    value: value,
    min: min,
    max: max,
    step: step,
    suffix: suffix,
    onChanged: widget.enabled ? (value) => update(() => change(value)) : null,
  );
  Widget styleButton(
    String label,
    IconData icon,
    bool selected,
    VoidCallback toggle,
  ) => IconButton(
    tooltip: label,
    isSelected: selected,
    selectedIcon: Icon(icon, color: StudioColors.accent),
    onPressed: widget.enabled ? () => update(toggle) : null,
    icon: Icon(icon),
  );
  @override
  Widget build(BuildContext context) {
    final element = widget.element;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (element.kind != ElementKind.image) ...[
          TextField(
            controller: text,
            enabled: widget.enabled,
            maxLines: element.kind == ElementKind.text ? 3 : 2,
            decoration: InputDecoration(
              labelText: element.kind == ElementKind.qr
                  ? 'Содержимое QR'
                  : 'Текст',
            ),
            onChanged: (value) => update(
              () => element.text = value,
              image: element.kind == ElementKind.qr,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (element.kind == ElementKind.text) ...[
          DropdownButtonFormField<String>(
            initialValue: element.fontFamily,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Шрифт'),
            items: studioFonts
                .map(
                  (font) => DropdownMenuItem(
                    value: font.family,
                    child: Text(
                      font.label,
                      style: TextStyle(fontFamily: font.family),
                    ),
                  ),
                )
                .toList(),
            onChanged: widget.enabled
                ? (family) {
                    if (family != null) {
                      update(() => element.fontFamily = family);
                    }
                  }
                : null,
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              styleButton(
                'Жирный',
                Icons.format_bold,
                element.bold,
                () => element.bold = !element.bold,
              ),
              styleButton(
                'Курсив',
                Icons.format_italic,
                element.italic,
                () => element.italic = !element.italic,
              ),
              styleButton(
                'Подчёркнутый',
                Icons.format_underlined,
                element.underline,
                () => element.underline = !element.underline,
              ),
              styleButton(
                'Зачёркнутый',
                Icons.format_strikethrough,
                element.strikethrough,
                () => element.strikethrough = !element.strikethrough,
              ),
            ],
          ),
          control(
            'Размер шрифта',
            element.fontSize,
            1,
            300,
            (value) => element.fontSize = value,
          ),
        ],
        if (element.kind == ElementKind.qr)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'QR без белого фона. Не накладывайте другие объекты '
              'на код и его свободную зону в 4 модуля: сканирование может не работать.',
              style: TextStyle(color: StudioColors.accent, fontSize: 12),
            ),
          ),
        control(
          'Ширина',
          element.width,
          1,
          LabelDocument.maxElementWidth,
          (value) => scaleElement(
            element,
            value / element.width,
            element.aspectLocked ? value / element.width : 1,
          ),
          suffix: 'т.',
        ),
        control(
          'Высота',
          element.height,
          1,
          1200,
          (value) => scaleElement(
            element,
            element.aspectLocked ? value / element.height : 1,
            value / element.height,
          ),
          suffix: 'т.',
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Сохранять пропорции'),
          subtitle: const Text('Выключите для независимой ширины и высоты'),
          value: element.aspectLocked,
          onChanged: widget.enabled
              ? (value) => update(() => element.aspectLocked = value)
              : null,
        ),
        if (element.kind == ElementKind.text && !element.aspectLocked) ...[
          const SizedBox(height: 8),
          SegmentedButton<TextResizeMode>(
            segments: const [
              ButtonSegment(
                value: TextResizeMode.box,
                icon: Icon(Icons.crop_free),
                label: Text('Рамка'),
              ),
              ButtonSegment(
                value: TextResizeMode.stretch,
                icon: Icon(Icons.text_fields),
                label: Text('Текст'),
              ),
            ],
            selected: {element.textResizeMode},
            onSelectionChanged: widget.enabled
                ? (selection) => update(() {
                    element.textResizeMode = selection.single;
                    if (element.textResizeMode == TextResizeMode.box) {
                      element.textScaleX = 1;
                      element.textScaleY = 1;
                    }
                  })
                : null,
          ),
          const SizedBox(height: 8),
          Text(
            element.textResizeMode == TextResizeMode.box
                ? 'Рамка меняет переносы строк, размер шрифта остаётся прежним.'
                : 'Текст растягивает сами буквы по ширине и высоте.',
            style: const TextStyle(color: StudioColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
        ],
        control(
          'Поворот',
          element.rotation * 180 / math.pi,
          -3600,
          3600,
          (value) => element.rotation = value * math.pi / 180,
          step: 5,
          suffix: '°',
        ),
        if (element.kind == ElementKind.image) ...[
          const Divider(height: 24),
          DropdownButtonFormField<RasterMode>(
            initialValue: element.settings.mode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Преобразование в ч/б',
            ),
            items: RasterMode.values
                .map(
                  (mode) => DropdownMenuItem(
                    value: mode,
                    child: Text(switch (mode) {
                      RasterMode.threshold => 'Порог',
                      RasterMode.ordered => 'Bayer · упорядоченный',
                      RasterMode.diffusion => 'Floyd–Steinberg · дизеринг',
                      RasterMode.edges => 'Sobel · контуры',
                    }, style: const TextStyle(fontSize: 13)),
                  ),
                )
                .toList(),
            onChanged: widget.enabled
                ? (mode) {
                    if (mode != null) {
                      update(
                        () => element.settings = element.settings.copyWith(
                          mode: mode,
                        ),
                        image: true,
                      );
                    }
                  }
                : null,
          ),
          NumberControl(
            label: 'Порог',
            value: element.settings.threshold.toDouble(),
            min: 0,
            max: 255,
            step: 8,
            onChanged: widget.enabled
                ? (value) => update(
                    () => element.settings = element.settings.copyWith(
                      threshold: value.round(),
                    ),
                    image: true,
                  )
                : null,
          ),
          NumberControl(
            label: 'Яркость',
            value: element.settings.brightness,
            min: -100,
            max: 100,
            step: 5,
            onChanged: widget.enabled
                ? (value) => update(
                    () => element.settings = element.settings.copyWith(
                      brightness: value,
                    ),
                    image: true,
                  )
                : null,
          ),
          NumberControl(
            label: 'Контраст',
            value: element.settings.contrast * 100,
            min: 20,
            max: 300,
            step: 10,
            suffix: '%',
            onChanged: widget.enabled
                ? (value) => update(
                    () => element.settings = element.settings.copyWith(
                      contrast: value / 100,
                    ),
                    image: true,
                  )
                : null,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Инверсия'),
            value: element.settings.invert,
            onChanged: widget.enabled
                ? (value) => update(
                    () => element.settings = element.settings.copyWith(
                      invert: value,
                    ),
                    image: true,
                  )
                : null,
          ),
        ],
        const SizedBox(height: 8),
        TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: StudioColors.red),
          onPressed: widget.enabled ? widget.onDelete : null,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Удалить объект'),
        ),
      ],
    );
  }
}

class StickerPrintDialog extends StatefulWidget {
  const StickerPrintDialog({
    required this.document,
    required this.printTile,
    super.key,
  });
  final LabelDocument document;
  final Future<void> Function(int index) printTile;
  @override
  State<StickerPrintDialog> createState() => _StickerPrintDialogState();
}

class _StickerPrintDialogState extends State<StickerPrintDialog> {
  late final job = StickerPrintJob(
    tileCount: widget.document.tileCount,
    printTile: widget.printTile,
  );
  bool placementReady = false;

  @override
  void initState() {
    super.initState();
    job.addListener(jobChanged);
    unawaited(job.printNext());
  }

  void jobChanged() {
    if (mounted) setState(() => placementReady = false);
  }

  @override
  void dispose() {
    job.removeListener(jobChanged);
    job.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    final placing = job.phase == StickerPrintPhase.placement;
    final printing = job.phase == StickerPrintPhase.printing;
    final terminal = switch (job.phase) {
      StickerPrintPhase.completed ||
      StickerPrintPhase.failed ||
      StickerPrintPhase.cancelled => true,
      _ => false,
    };
    final tile = math.max(0, job.index);
    final status = switch (job.phase) {
      StickerPrintPhase.ready => 'Подготовка сборки',
      StickerPrintPhase.printing =>
        'Печать ${tile + 1} / ${job.tileCount} · ожидаем подтверждение принтера',
      StickerPrintPhase.placement =>
        'Наклейте ${tile + 1} в строку ${tile ~/ document.columns + 1}, '
            'столбец ${tile % document.columns + 1}',
      StickerPrintPhase.completed => 'Все наклейки размещены',
      StickerPrintPhase.cancelled =>
        job.transactionActive
            ? 'Отменено. Уже отправленная наклейка ещё может напечататься; '
                  'ожидаем завершение текущей операции.'
            : 'Сборка отменена. Следующие наклейки не отправлены.',
      StickerPrintPhase.failed =>
        'Сборка остановлена на наклейке ${tile + 1}. '
            'Результат этой операции может быть неизвестен. '
            'Повторная печать не запускается.\n${job.error}\n'
            'Проверьте принтер и уже вышедшие наклейки перед новым заданием.',
    };
    return PopScope(
      canPop: false,
      child: Dialog.fullscreen(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Text(
                  'Сборка ${document.rows} × ${document.columns}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: printing
                      ? null
                      : ((tile +
                                    (placing ||
                                            job.phase ==
                                                StickerPrintPhase.completed
                                        ? 1
                                        : 0)) /
                                job.tileCount)
                            .clamp(0.0, 1.0),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Text(
                      status,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: job.phase == StickerPrintPhase.failed
                            ? StudioColors.red
                            : StudioColors.text,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final scale = math.min(
                        constraints.maxWidth / document.width,
                        constraints.maxHeight / document.canvasHeight,
                      );
                      return Center(
                        child: SizedBox(
                          width: document.width * scale,
                          height: document.canvasHeight * scale,
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey('${job.index}-${job.phase.name}'),
                            tween: Tween(begin: 0, end: placing ? 1 : 0),
                            duration: const Duration(milliseconds: 650),
                            curve: Curves.easeOutCubic,
                            onEnd: placing
                                ? () {
                                    if (mounted &&
                                        job.phase ==
                                            StickerPrintPhase.placement) {
                                      setState(() => placementReady = true);
                                    }
                                  }
                                : null,
                            builder: (context, progress, child) => CustomPaint(
                              painter: StickerPlacementPainter(
                                document,
                                scale,
                                tile,
                                placing ||
                                    job.phase == StickerPrintPhase.completed,
                                progress,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Порядок: слева направо, затем следующая строка. '
                  'Ориентация макета соответствует размещению; зазор ленты '
                  'не добавляется к сборке.',
                  style: TextStyle(color: StudioColors.muted, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (!terminal)
                      OutlinedButton(
                        onPressed: job.cancel,
                        child: const Text('Отменить сборку'),
                      ),
                    if (placing)
                      FilledButton(
                        onPressed: placementReady
                            ? () => unawaited(job.printNext())
                            : null,
                        child: Text(
                          tile + 1 == job.tileCount
                              ? 'Наклеено · завершить'
                              : 'Наклеено · печатать следующую',
                        ),
                      ),
                    if (terminal)
                      FilledButton(
                        onPressed: job.transactionActive
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('Закрыть'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StickerPlacementPainter extends CustomPainter {
  StickerPlacementPainter(
    this.document,
    this.scale,
    this.index,
    this.acknowledged,
    this.progress,
  );
  final LabelDocument document;
  final double scale, progress;
  final int index;
  final bool acknowledged;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(scale);
    paintLabel(canvas, document);
    for (var i = 0; i < document.tileCount; i++) {
      final rect = document.tileRect(i);
      if (i > index || (i == index && !acknowledged)) {
        canvas.drawRect(rect, Paint()..color = const Color(0xaa282828));
      }
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            fontSize: 14 / scale,
            color: StudioColors.blue,
            backgroundColor: StudioColors.bg,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, rect.topLeft + Offset(4 / scale, 4 / scale));
      label.dispose();
    }
    paintTileSeams(canvas, document, scale);
    if (acknowledged) {
      final rect = document.tileRect(index);
      // Show the acknowledged sticker arriving at its actual grid position.
      final target = rect.shift(Offset(0, -(1 - progress) * rect.height * .7));
      canvas.drawRect(
        target,
        Paint()
          ..color = StudioColors.accent.withValues(alpha: .15 + .15 * progress),
      );
      canvas.drawRect(
        target.deflate(2 / scale),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / scale
          ..color = StudioColors.accent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant StickerPlacementPainter oldDelegate) =>
      oldDelegate.index != index ||
      oldDelegate.acknowledged != acknowledged ||
      oldDelegate.progress != progress ||
      oldDelegate.scale != scale;
}

class DeviceDialog extends StatefulWidget {
  const DeviceDialog({required this.discover, super.key});
  final Future<List<PrinterDevice>> Function() discover;
  @override
  State<DeviceDialog> createState() => _DeviceDialogState();
}

class _DeviceDialogState extends State<DeviceDialog> {
  late Future<List<PrinterDevice>> devices;
  bool searching = true;

  @override
  void initState() {
    super.initState();
    // Discovery notifies the editor; do not start it during the overlay build.
    devices = Future.microtask(loadDevices);
  }

  Future<List<PrinterDevice>> loadDevices() async {
    try {
      return await widget.discover();
    } finally {
      if (mounted) setState(() => searching = false);
    }
  }

  final address = TextEditingController();
  @override
  void dispose() {
    address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Подключить D110'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Включите принтер. Выберите классический Bluetooth D110, не имя с суффиксом _BLE.',
            ),
            const SizedBox(height: 16),
            FutureBuilder<List<PrinterDevice>>(
              future: devices,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text(
                    'Поиск: ${snapshot.error}. Можно ввести MAC вручную.',
                  );
                }
                if (!snapshot.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(),
                  );
                }
                final found = snapshot.data!;
                if (found.isEmpty) {
                  return const Text(
                    'Устройства не найдены. На десктопе сначала найдите принтер в настройках Bluetooth или введите MAC.',
                  );
                }
                return Column(
                  children: found
                      .map(
                        (device) => ListTile(
                          leading: const Icon(Icons.print_outlined),
                          title: Text(device.name),
                          subtitle: Text(device.address),
                          onTap: () => Navigator.pop(context, device.address),
                        ),
                      )
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: address,
              decoration: const InputDecoration(
                labelText: 'MAC-адрес вручную',
                hintText: 'AA:BB:CC:DD:EE:FF',
              ),
              textCapitalization: TextCapitalization.characters,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: searching
            ? null
            : () => setState(() {
                searching = true;
                devices = loadDevices();
              }),
        child: const Text('Обновить'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: searching
            ? null
            : () {
                final value = address.text.trim().toUpperCase();
                if (RegExp(
                  r'^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$',
                ).hasMatch(value)) {
                  Navigator.pop(context, value);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Введите MAC в формате AA:BB:CC:DD:EE:FF'),
                    ),
                  );
                }
              },
        child: const Text('Подключить'),
      ),
    ],
  );
}
