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
import 'printer_battery.dart';
import 'battery_view.dart';
import 'drawing.dart';
import 'shortener.dart';
import 'qr_calibration.dart';
import 'app_state_store.dart';
import 'last_printed.dart';
import 'workspace.dart';
import 'media_geometry.dart';
import 'media_calibration.dart';
import 'print_quantity.dart';

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
  final stateStore = AppStateStore();
  late final lastPrinted = LastPrintedHistory(stateStore);
  MediaProfile _defaultMedia = MediaProfile();
  String? _mediaError;
  late DesignWorkspace workspace = DesignWorkspace(
    LabelDocument(
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
    ),
  );
  DesignTab get activeTab => workspace.active;
  LabelDocument get document => activeTab.document;
  LabelElement? get selected => activeTab.selected;
  set selected(LabelElement? value) => activeTab.selected = value;
  List<Map<String, dynamic>> templates = [];
  late final connection = PrinterConnectionController(printer);
  late final battery = PrinterBatteryController(connection);
  String? error;
  bool busy = true;
  bool get preview => activeTab.preview;
  set preview(bool value) => activeTab.preview = value;
  bool get inspectorOpen => activeTab.inspectorOpen;
  set inspectorOpen(bool value) => activeTab.inspectorOpen = value;
  bool get colorImages => activeTab.colorImages;
  set colorImages(bool value) => activeTab.colorImages = value;
  ui.Image? get previewImage => activeTab.previewImage;
  Timer? _workspaceTimer;
  Future<void> _stateWrites = Future.value();
  bool _stateReady = false;
  String? _storageError;
  (String, String, bool, double)? _tabRevealState;
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
  double get viewZoom => activeTab.viewZoom;
  set viewZoom(double value) => activeTab.viewZoom = value;
  Offset get viewPan => activeTab.viewPan;
  set viewPan(Offset value) => activeTab.viewPan = value;
  bool zoomingLabel = false;
  double startZoom = 1;
  Offset startPan = Offset.zero;
  Offset? zoomFocal;
  late final AnimationController ants = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..repeat();
  int get revision => activeTab.revision;
  set revision(int value) => activeTab.revision = value;
  bool get native => !kIsWeb;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    connection.addListener(_connectionChanged);
    selected = document.elements.first;
    unawaited(_restoreWorkspace());
    if (native) unawaited(_loadTemplates());
    if (native) {
      connection.setForeground(
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
      battery.setForeground(
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      );
      unawaited(connection.restore());
    }
  }

  void _connectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (native) {
      connection.setForeground(state == AppLifecycleState.resumed);
      battery.setForeground(state == AppLifecycleState.resumed);
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _workspaceTimer?.cancel();
      unawaited(_persistWorkspace());
    }
  }

  Future<void> _restoreWorkspace() async {
    String? drafts;
    String? printed;
    var draftsReadable = true;
    try {
      final saved = await stateStore.read(AppStateSlot.mediaProfile);
      if (saved != null) {
        _defaultMedia = MediaProfile.fromJson(
          Map<String, dynamic>.from(jsonDecode(saved) as Map),
        );
      }
    } catch (e) {
      _mediaError = 'Профиль ленты не загружен; размеры не измерены: $e';
    }
    try {
      drafts = await stateStore.read(AppStateSlot.workspace);
    } catch (e) {
      draftsReadable = false;
      _storageError = 'Черновики не загружены и не будут перезаписаны: $e';
    }
    try {
      printed = await lastPrinted.readSnapshot();
    } catch (e) {
      _storageError =
          '${_storageError == null ? '' : '${_storageError!}\n'}'
          'Последний отпечаток не загружен: $e';
    }
    try {
      if (drafts != null || printed != null) {
        final next = await DesignWorkspace.restore(
          drafts,
          printedSnapshot: printed,
        );
        if (drafts == null && next.printedRestoreError != null) {
          next.active.document.media = _defaultMedia;
        }
        if (!mounted) {
          next.dispose();
          return;
        }
        workspace.dispose();
        workspace = next;
        if (next.printedRestoreError != null) {
          _storageError =
              '${_storageError == null ? '' : '${_storageError!}\n'}'
              '${next.printedRestoreError}';
        }
      } else {
        document.media = _defaultMedia;
        activeTab.revision++;
      }
      _stateReady = draftsReadable;
    } catch (e) {
      _storageError = 'Черновики не восстановлены и не будут перезаписаны: $e';
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (preview) refreshPreview();
        _saveWorkspaceSoon();
      }
    }
  }

  void _saveWorkspaceSoon() {
    if (!_stateReady) return;
    _workspaceTimer?.cancel();
    _workspaceTimer = Timer(const Duration(milliseconds: 200), () {
      unawaited(_persistWorkspace());
    });
  }

  Future<void> _persistWorkspace() {
    if (!_stateReady) return Future.value();
    final snapshot = jsonEncode(workspace.toJson());
    final write = _stateWrites.then(
      (_) => stateStore.write(AppStateSlot.workspace, snapshot),
    );
    _stateWrites = write.then<void>(
      (_) {
        if (mounted &&
            _storageError?.startsWith('Черновики не сохранены') == true) {
          setState(() => _storageError = null);
        }
      },
      onError: (Object e, StackTrace stack) {
        if (mounted) {
          setState(() => _storageError = 'Черновики не сохранены: $e');
        }
      },
    );
    return _stateWrites;
  }

  void _resetGesture() {
    dragPoint = pointerDown = zoomFocal = null;
    activeHandle = pointerHandle = null;
    selectionBounds = null;
    zoomingLabel = false;
  }

  void activateTab(String id) {
    if (busy || id == workspace.activeId) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      workspace.activate(id);
      _resetGesture();
    });
    if (preview) refreshPreview();
    _saveWorkspaceSoon();
  }

  LabelDocument createDesignDocument(String name) =>
      LabelDocument(name: name, media: _defaultMedia);

  void applyMediaProfile(MediaProfile profile) {
    document.media = profile;
    viewZoom = 1;
    viewPan = Offset.zero;
    changed();
  }

  Future<void> calibrateMedia() => action(() async {
    final target = document;
    final profile = await showMediaCalibration(
      context,
      initial: target.media,
      canPrint:
          native && printer.connected && !printer.busy && !connection.busy,
      canPrintNow: () =>
          native && printer.connected && !printer.busy && !connection.busy,
      printerChanges: Listenable.merge([printer, connection]),
      pickImage: () => pickStudioImage(printer),
      readSession: () => stateStore.read(AppStateSlot.mediaCalibration),
      saveSession: (json) =>
          stateStore.write(AppStateSlot.mediaCalibration, json),
      printPattern: (raster) =>
          printer.printRaster(raster.packed, raster.height, density: 1),
      saveProfile: (profile) async {
        if (!LabelDocument.fitsLayout(
          profile,
          target.rows,
          target.columns,
          trimMargins: target.trimMargins,
        )) {
          throw StateError(
            'Сначала уменьшите сетку: макет с этой лентой превышает 16 Мпикс.',
          );
        }
        await stateStore.write(
          AppStateSlot.mediaProfile,
          jsonEncode(profile.toJson()),
        );
      },
    );
    if (profile == null || !mounted || document != target) return;
    _defaultMedia = profile;
    _mediaError = null;
    applyMediaProfile(profile);
  });

  Future<void> newDesign() => action(() async {
    final name = await askText('Название макета', 'Новый макет');
    if (name == null || name.trim().isEmpty || !mounted) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      workspace.create(createDesignDocument(name.trim()));
      _resetGesture();
    });
    _saveWorkspaceSoon();
  });

  Future<void> renameDesign() => action(() async {
    final name = await askText('Переименовать макет', document.name);
    if (name == null || name.trim().isEmpty || !mounted) return;
    document.name = name.trim();
    changed();
  });

  Future<void> closeDesign(String id) => action(() async {
    final tab = workspace.tabs.firstWhere((tab) => tab.id == id);
    var discard = false;
    if (tab.dirty) {
      discard =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Закрыть «${tab.document.name}»?'),
              content: const Text(
                'Изменённый черновик будет удалён из вкладок. '
                'Сохранённые шаблоны и последний подтверждённый отпечаток останутся.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Оставить'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Закрыть и удалить черновик'),
                ),
              ],
            ),
          ) ==
          true;
      if (!discard || !mounted) return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      if (workspace.tabs.length == 1) {
        workspace.create(createDesignDocument('Новый макет'));
      }
      workspace.close(id, discardChanges: discard);
      _resetGesture();
    });
    if (preview) refreshPreview();
    _workspaceTimer?.cancel();
    await _persistWorkspace();
  });

  Future<void> _recordPrinted(LastPrintedJob job) async {
    final warning = await job.confirmed();
    if (mounted && warning != null) setState(() => error = warning);
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
    battery.dispose();
    connection.dispose();
    ants.dispose();
    _workspaceTimer?.cancel();
    unawaited(_persistWorkspace());
    workspace.dispose();
    printer.dispose();
    super.dispose();
  }

  void changed() {
    setState(() => error = null);
    revision++;
    activeTab.dirty = true;
    activeTab.invalidatePreview();
    _saveWorkspaceSoon();
    if (preview) refreshPreview();
  }

  void refreshPreview() {
    final tab = activeTab;
    final version = ++tab.previewVersion;
    tab.previewTimer?.cancel();
    tab.previewTimer = Timer(const Duration(milliseconds: 80), () async {
      try {
        final next = await renderDesign(tab.document);
        if (!mounted || tab.disposed || version != tab.previewVersion) {
          next.dispose();
          return;
        }
        tab.previewImage?.dispose();
        tab.previewImage = next;
        if (activeTab == tab) setState(() {});
      } catch (e) {
        if (mounted &&
            !tab.disposed &&
            activeTab == tab &&
            version == tab.previewVersion) {
          setState(() => error = '$e');
        }
      }
    });
  }

  Future<void> action(Future<void> Function() operation) async {
    if (busy) return;
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
      if (!mounted) return;
      String? value;
      if (kind == ElementKind.qr) {
        value = await showQrTextDialog(context, 'https://example.com');
      } else {
        value = await askText('Текст', 'Новый текст');
      }
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

  Future<void> draw() => action(() async {
    final target = document;
    if (target.elements.length >= 100) {
      throw StateError('На этикетке уже 100 элементов');
    }
    final bytes = await showDrawingEditor(
      context,
      width: target.width,
      height: target.canvasHeight,
      media: target.media,
      rows: target.rows,
      columns: target.columns,
      trimMargins: target.trimMargins,
    );
    if (bytes == null || !mounted || document != target) return;
    final element = LabelElement(
      kind: ElementKind.image,
      imageBytes: bytes,
      inkOnly: true,
      x: 0,
      y: 0,
      width: target.width.toDouble(),
      height: target.canvasHeight.toDouble(),
    );
    try {
      await element.prepare();
      if (!mounted || document != target) {
        element.dispose();
        return;
      }
    } catch (_) {
      element.dispose();
      rethrow;
    }
    target.elements.add(element);
    selected = element;
    preview = false;
    changed();
  });
  Future<void> connect() => action(() async {
    var pickerOpen = true;
    connection.setSelectingPrinter(true);
    try {
      if (connection.phase == PrinterConnectionPhase.permissionRequired) {
        await connection.enableAndReconnect();
        if (!mounted ||
            connection.phase != PrinterConnectionPhase.selectPrinter) {
          return;
        }
      }
      Future<void> discoveryFinished = Future.value();
      Future<List<PrinterDevice>> discover() {
        final request = connection.discover(
          isCurrent: () => pickerOpen && mounted,
        );
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
      pickerOpen = false;
      await discoveryFinished;
      if (address == null || !mounted) return;
      await connection.connect(address);
    } finally {
      pickerOpen = false;
      connection.setSelectingPrinter(false);
    }
  });
  int density = 2;
  Future<void> print() => action(() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (document.elements.isEmpty) {
      throw StateError('Добавьте текст, QR или изображение');
    }
    final job = LastPrintedJob.capture(document, lastPrinted);
    final printedDocument = await job.prepare();
    try {
      if (!mounted) return;
      final copies = await showDialog<int>(
        context: context,
        builder: (_) =>
            PrintQuantityDialog(tilesPerDesign: printedDocument.tileCount),
      );
      if (copies == null || !mounted) return;
      final warnings = printWarnings(printedDocument);
      if (_defaultMedia.isCalibrated &&
          jsonEncode(printedDocument.media.toJson()) !=
              jsonEncode(_defaultMedia.toJson())) {
        warnings.insert(
          0,
          'Этот макет использует другой профиль ленты. При необходимости примените сохранённый профиль в настройках этикетки.',
        );
      }
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
      Future<void> printTile(int index) async {
        if (!printer.connected) {
          throw StateError(
            'Принтер отключён. Задание остановлено без повторной печати.',
          );
        }
        final raster = await renderTile(printedDocument, index);
        await printer.printRaster(
          raster.packed,
          raster.height,
          density: density,
        );
        if (index == printedDocument.tileCount - 1) {
          await _recordPrinted(job);
        }
      }

      if (copies == 1 && printedDocument.tileCount == 1) {
        await printTile(0);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Принтер подтвердил печать. Проверьте наклейку.'),
            ),
          );
        }
      } else {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => StickerPrintDialog(
            document: printedDocument,
            copies: copies,
            printTile: printTile,
          ),
        );
      }
    } finally {
      printedDocument.dispose();
    }
  });
  Future<void> save() => action(() async {
    final name = await askText('Название шаблона', document.name);
    if (name == null || name.trim().isEmpty || !mounted) return;
    document.name = name.trim();
    final saved = document.toJson();
    final next = templates.where((e) => e['name'] != document.name).toList()
      ..add(saved);
    try {
      await printer.saveTemplates(jsonEncode(next));
    } catch (_) {
      changed();
      rethrow;
    }
    if (!mounted) return;
    setState(() {
      templates = next;
      activeTab.dirty = false;
    });
    _saveWorkspaceSoon();
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
    final next = await prepareDocument(saved);
    if (!mounted) {
      next.dispose();
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      workspace.create(next);
      _resetGesture();
    });
    _saveWorkspaceSoon();
  });
  void mutateSelected(void Function(LabelElement) mutation) {
    if (busy || preview || selected == null) return;
    mutation(selected!);
    changed();
  }

  Future<void> prepareElement(LabelElement element) async {
    final tab = activeTab;
    try {
      await element.prepare();
      if (!mounted ||
          tab.disposed ||
          !tab.document.elements.contains(element)) {
        return;
      }
      tab.revision++;
      tab.dirty = true;
      tab.invalidatePreview();
      if (activeTab == tab) {
        setState(() {});
        if (tab.preview) refreshPreview();
      }
      _saveWorkspaceSoon();
    } catch (e) {
      if (mounted && !tab.disposed && activeTab == tab) {
        setState(() => error = '$e');
      }
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
    _saveWorkspaceSoon();
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
                    _saveWorkspaceSoon();
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
                        onSelectionChanged: (value) {
                          setState(() => colorImages = value.single);
                          _saveWorkspaceSoon();
                        },
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

  void labelSettings() {
    String? lengthError;
    unawaited(
      sheet(
        'Этикетка и принтер',
        (context) => StatefulBuilder(
          builder: (context, update) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Одна наклейка: ${document.lengthMm} × ${document.media.widthMm} мм, '
                'радиус ${document.media.radiusMm} мм.\n'
                'Бумага: ${document.tileWidth} × ${document.tileHeight} точек; '
                'головка всегда 96 точек, без масштабирования.\n'
                '${document.media.name} · ${document.media.isCalibrated ? 'измерено ${document.media.measuredAt!.toLocal()}' : 'геометрия не измерена'}.\n'
                'Оранжевое поле вне головки не печатается. Зазор между стикерами не входит в макет.',
              ),
              if (_defaultMedia.isCalibrated &&
                  jsonEncode(document.media.toJson()) !=
                      jsonEncode(_defaultMedia.toJson()))
                OutlinedButton.icon(
                  icon: const Icon(Icons.straighten),
                  label: Text('Применить профиль «${_defaultMedia.name}»'),
                  onPressed:
                      busy ||
                          !LabelDocument.fitsLayout(
                            _defaultMedia,
                            document.rows,
                            document.columns,
                            trimMargins: document.trimMargins,
                          )
                      ? null
                      : () {
                          applyMediaProfile(_defaultMedia);
                          update(() => lengthError = null);
                        },
                ),
              const SizedBox(height: 16),
              NumberControl(
                label: 'Длина',
                value: document.lengthMm.toDouble(),
                min: 10,
                max: math.min(
                  150.0,
                  (LabelDocument.maxCanvasPixels ~/
                          (document.tileHeight *
                              document.rows *
                              document.columns)) /
                      mediaDotsPerMm,
                ),
                step: 1 / mediaDotsPerMm,
                suffix: 'мм',
                onChanged: busy
                    ? null
                    : (value) {
                        try {
                          document.lengthMm = value;
                        } on ArgumentError catch (error) {
                          update(() {
                            lengthError = error.message.toString();
                          });
                          return;
                        }
                        changed();
                        update(() => lengthError = null);
                      },
              ),
              if (lengthError != null)
                Text(
                  lengthError!,
                  key: const ValueKey('media-edit-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              const Divider(height: 24),
              const Text('Сборка из наклеек · единый макет'),
              NumberControl(
                label: 'Столбцы',
                value: document.columns.toDouble(),
                min: 1,
                max: math
                    .min(
                      8,
                      LabelDocument.maxCanvasPixels ~/
                          (document.tileWidth *
                              document.tileHeight *
                              document.rows),
                    )
                    .toDouble(),
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
                max: math
                    .min(
                      8,
                      LabelDocument.maxCanvasPixels ~/
                          (document.tileWidth *
                              document.tileHeight *
                              document.columns),
                    )
                    .toDouble(),
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
                '${document.width / mediaDotsPerMm} × '
                '${document.canvasHeight / mediaDotsPerMm} мм.\n'
                'Печать по строкам слева направо. Между наклейками '
                'нужно подтвердить размещение; швы на макете не печатаются.',
                style: const TextStyle(color: StudioColors.muted, fontSize: 12),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Стек без белых швов · обрезать края'),
                subtitle: Text(
                  document.media.isCalibrated
                      ? 'Обрежьте каждую наклейку до ${document.media.safeRect.width / mediaDotsPerMm} × '
                            '${document.media.safeRect.height / mediaDotsPerMm} мм перед склейкой. '
                            'Размеры объектов не меняются; проверьте их положение.'
                      : 'Сначала откалибруйте ленту. Непечатаемые края нужно срезать.',
                ),
                value: document.trimMargins,
                onChanged:
                    busy ||
                        !document.media.isCalibrated ||
                        document.media.safeRect.isEmpty
                    ? null
                    : (value) {
                        document.trimMargins = value;
                        viewZoom = 1;
                        viewPan = Offset.zero;
                        changed();
                        update(() {});
                      },
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
  }

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
                      _saveWorkspaceSoon();
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
                            _saveWorkspaceSoon();
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
                      _saveWorkspaceSoon();
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

  void _revealActiveDesign(double viewportWidth) {
    final tab = activeTab;
    final state = (tab.id, tab.document.name, tab.dirty, viewportWidth);
    if (_tabRevealState == state) return;
    _tabRevealState = state;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || activeTab != tab) return;
      final target = GlobalObjectKey(tab).currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: .5);
      }
    });
  }

  Widget designTabs() => Container(
    height: 52,
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: StudioColors.border)),
    ),
    child: Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _revealActiveDesign(constraints.maxWidth);
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final tab in workspace.tabs)
                      Padding(
                        key: GlobalObjectKey(tab),
                        padding: const EdgeInsets.only(left: 4),
                        child: Material(
                          color: tab == activeTab
                              ? StudioColors.border
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Tooltip(
                                message:
                                    '${tab.document.name}'
                                    '${tab.dirty ? ' · изменённый черновик' : ''}',
                                child: TextButton(
                                  key: ValueKey('activate-${tab.id}'),
                                  onPressed: busy
                                      ? null
                                      : () => activateTab(tab.id),
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 140,
                                    ),
                                    child: Text(
                                      '${tab.dirty ? '• ' : ''}${tab.document.name}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ),
                              IconButton(
                                key: ValueKey('close-${tab.id}'),
                                tooltip: 'Закрыть ${tab.document.name}',
                                onPressed: busy
                                    ? null
                                    : () => closeDesign(tab.id),
                                iconSize: 18,
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        IconButton(
          tooltip: 'Переименовать макет',
          onPressed: busy ? null : renameDesign,
          icon: const Icon(Icons.drive_file_rename_outline),
        ),
        IconButton(
          tooltip: 'Новый макет',
          onPressed: busy ? null : newDesign,
          icon: const Icon(Icons.add),
        ),
      ],
    ),
  );

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
        leading: AnimatedBuilder(
          animation: battery,
          builder: (context, _) {
            final percent = battery.percent;
            final icon = switch (percent) {
              null => Icons.battery_unknown,
              0 => Icons.battery_0_bar,
              <= 15 => Icons.battery_1_bar,
              <= 30 => Icons.battery_2_bar,
              <= 45 => Icons.battery_3_bar,
              <= 60 => Icons.battery_4_bar,
              <= 75 => Icons.battery_5_bar,
              < 100 => Icons.battery_6_bar,
              _ => Icons.battery_full,
            };
            return Semantics(
              label: percent == null
                  ? 'Заряд принтера неизвестен'
                  : 'Заряд принтера: $percent%',
              child: IconButton(
                tooltip: 'Батарея принтера',
                onPressed: () => showPrinterBattery(context, battery),
                icon: Icon(
                  icon,
                  color: percent == null
                      ? StudioColors.muted
                      : percent <= 15
                      ? StudioColors.red
                      : StudioColors.green,
                ),
              ),
            );
          },
        ),
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
            tooltip: 'Калибровка ленты',
            icon: const Icon(Icons.straighten),
            onPressed: busy ? null : calibrateMedia,
          ),
          IconButton(
            tooltip: 'Калибровка QR на принтере',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: native && printer.connected && !busy && !connection.busy
                ? () => action(
                    () => showQrCalibration(
                      context,
                      printer,
                      media: document.media,
                    ),
                  )
                : null,
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
                    _saveWorkspaceSoon();
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
                designTabs(),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  child: Text(
                    '${document.lengthMm} × ${document.media.widthMm} мм · '
                    'R ${document.media.radiusMm} мм · '
                    '${document.media.isCalibrated ? 'лента измерена' : 'лента не измерена'}',
                    style: const TextStyle(
                      color: StudioColors.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (_mediaError != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _mediaError!,
                      style: const TextStyle(color: StudioColors.red),
                    ),
                  ),
                if (_storageError != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      _storageError!,
                      style: const TextStyle(color: StudioColors.red),
                    ),
                  ),
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
                Expanded(
                  child: KeyedSubtree(
                    key: ValueKey('editor-${activeTab.id}'),
                    child: editorWorkspace(),
                  ),
                ),
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
                              Icons.draw_outlined,
                              'Рисунок',
                              busy ? null : draw,
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
                                    ? () => action(connection.disconnect)
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
  var maxY = LabelDocument.maxElementHeight / element.height;
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
    canvas.drawRect(
      Rect.fromLTWH(
        0,
        0,
        document.width.toDouble(),
        document.canvasHeight.toDouble(),
      ),
      Paint()..color = StudioColors.border,
    );
    canvas.drawPath(
      document.paperPath,
      Paint()..color = StudioColors.accent.withValues(alpha: .35),
    );
    canvas.save();
    canvas.clipPath(document.printablePath, doAntiAlias: false);
    if (preview != null) {
      canvas.drawImage(
        preview!,
        Offset.zero,
        Paint()..filterQuality = FilterQuality.none,
      );
    } else {
      paintLabel(canvas, document, colorImages: colorImages);
    }
    canvas.restore();
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
    final y = (row * document.tileHeight).toDouble();
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
    this.sliderSpan,
    super.key,
  });
  final String label, suffix;
  final double value, min, max, step;
  final double? sliderSpan;
  final ValueChanged<double>? onChanged;
  @override
  State<NumberControl> createState() => _NumberControlState();
}

class _NumberControlState extends State<NumberControl> {
  late final controller = TextEditingController(text: displayValue);
  final focus = FocusNode();
  final sliderFocus = FocusNode();
  (double, double)? dragRange;
  String format(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
  String get displayValue => format(widget.value);
  String withUnit(double value) =>
      '${format(value)}${widget.suffix.isEmpty ? '' : ' ${widget.suffix}'}';

  (double, double) get sliderRange {
    if (dragRange case final range?) return range;
    final steps = ((widget.max - widget.min) / widget.step).floor();
    final span =
        widget.sliderSpan ??
        (steps > 2048 ? widget.step * 1024 : widget.max - widget.min);
    final window = math.min(steps, (span / widget.step).round());
    final current = ((widget.value - widget.min) / widget.step).round();
    final start = (current - window ~/ 2).clamp(0, steps - window);
    return (
      widget.min + start * widget.step,
      widget.min + (start + window) * widget.step,
    );
  }

  @override
  void didUpdateWidget(covariant NumberControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onChanged == null && oldWidget.onChanged != null) {
      focus.unfocus();
      sliderFocus.unfocus();
      controller.text = displayValue;
    }
    if (oldWidget.min != widget.min ||
        oldWidget.max != widget.max ||
        widget.onChanged == null) {
      dragRange = null;
    }
    if (oldWidget.value != widget.value && !focus.hasFocus) {
      controller.text = displayValue;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    sliderFocus.dispose();
    super.dispose();
  }

  void submit(String text) {
    if (widget.onChanged == null) {
      controller.text = displayValue;
      return;
    }
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
  Widget build(BuildContext context) {
    final (lower, upper) = sliderRange;
    final divisions = ((upper - lower) / widget.step).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(widget.label)),
              const SizedBox(width: 12),
              SizedBox(
                width: 120,
                child: Semantics(
                  label: '${widget.label}: точное значение',
                  child: TextField(
                    controller: controller,
                    focusNode: focus,
                    enabled: widget.onChanged != null,
                    textAlign: TextAlign.center,
                    textInputAction: TextInputAction.done,
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
                      focus.unfocus();
                    },
                  ),
                ),
              ),
            ],
          ),
          Semantics(
            label: widget.label,
            child: Slider(
              value: widget.value.clamp(lower, upper),
              min: lower,
              max: upper,
              divisions: divisions > 0 ? divisions : null,
              focusNode: sliderFocus,
              label: withUnit(widget.value),
              semanticFormatterCallback: withUnit,
              onChangeStart: widget.onChanged == null || divisions == 0
                  ? null
                  : (_) {
                      // Keep the window fixed until release, even as the canvas updates.
                      setState(() => dragRange = (lower, upper));
                      focus.unfocus();
                      sliderFocus.requestFocus();
                      controller.text = displayValue;
                    },
              onChanged: widget.onChanged == null || divisions == 0
                  ? null
                  : (value) {
                      final steps = ((value - widget.min) / widget.step)
                          .round();
                      widget.onChanged!(
                        (widget.min + steps * widget.step).clamp(
                          widget.min,
                          widget.max,
                        ),
                      );
                    },
              onChangeEnd: widget.onChanged == null || divisions == 0
                  ? null
                  : (_) => setState(() => dragRange = null),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                withUnit(lower),
                style: const TextStyle(color: StudioColors.muted, fontSize: 11),
              ),
              Text(
                withUnit(upper),
                style: const TextStyle(color: StudioColors.muted, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
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
    double? sliderSpan,
  }) => NumberControl(
    label: label,
    value: value,
    min: min,
    max: max,
    step: step,
    suffix: suffix,
    sliderSpan: sliderSpan,
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
        if (element.kind == ElementKind.qr)
          TextButton.icon(
            icon: const Icon(Icons.link),
            label: const Text('Изменить QR / сократить ссылку'),
            onPressed: widget.enabled
                ? () async {
                    final value = await showQrTextDialog(context, element.text);
                    if (!mounted || value == null || value.isEmpty) return;
                    text.text = value;
                    element.text = value;
                    widget.onImageChanged();
                  }
                : null,
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
          LabelDocument.maxElementHeight,
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
          suffix: '°',
          sliderSpan: 720,
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
    this.copies = 1,
    super.key,
  });
  final LabelDocument document;
  final int copies;
  final Future<void> Function(int index) printTile;
  @override
  State<StickerPrintDialog> createState() => _StickerPrintDialogState();
}

class _StickerPrintDialogState extends State<StickerPrintDialog> {
  late final job = StickerPrintJob(
    tileCount: widget.document.tileCount,
    printTile: widget.printTile,
    copies: widget.copies,
    waitForPlacement: widget.document.tileCount > 1,
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
    final tile = job.tileIndex;
    final status = switch (job.phase) {
      StickerPrintPhase.ready => 'Подготовка сборки',
      StickerPrintPhase.printing =>
        'Печать ${job.index + 1} / ${job.totalCount} · ожидаем подтверждение принтера',
      StickerPrintPhase.placement =>
        'Копия ${job.copyIndex + 1} / ${job.copies} · наклейте ${tile + 1} '
            'в строку ${tile ~/ document.columns + 1}, столбец ${tile % document.columns + 1}',
      StickerPrintPhase.completed =>
        document.tileCount > 1
            ? 'Все наклейки размещены'
            : 'Принтер подтвердил печать ${job.copies} копий. Проверьте наклейки.',
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
                  document.tileCount > 1
                      ? 'Сборка ${document.rows} × ${document.columns} · '
                            'копия ${job.copyIndex + 1} / ${job.copies}'
                      : 'Печать · ${job.copies} копий',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: printing
                      ? null
                      : ((job.index +
                                    (placing ||
                                            job.phase ==
                                                StickerPrintPhase.completed
                                        ? 1
                                        : 0)) /
                                job.totalCount)
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
                if (document.tileCount > 1)
                  Text(
                    document.trimMargins
                        ? 'Срежьте белые края до ${document.tileWidth / mediaDotsPerMm} × '
                              '${document.tileHeight / mediaDotsPerMm} мм. '
                              'Склейте обрезанные прямоугольники без зазора.'
                        : 'Слева направо, затем следующая строка. '
                              'Перед следующей копией начните новую сборку.',
                    style: const TextStyle(
                      color: StudioColors.muted,
                      fontSize: 12,
                    ),
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
                          job.index + 1 == job.totalCount
                              ? 'Наклеено · завершить'
                              : tile + 1 == job.tileCount
                              ? 'Наклеено · новая копия'
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
              'Показаны кандидаты D110 с классическим Bluetooth. BLE/GATT-устройства и несовместимые сервисы скрыты. Модель проверяется при подключении.',
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
                    'Подходящие D110 не найдены. На десктопе сначала найдите принтер в настройках Bluetooth или введите его MAC.',
                  );
                }
                return Column(
                  children: found
                      .map(
                        (device) => ListTile(
                          leading: const Icon(Icons.print_outlined),
                          title: Text(device.name),
                          subtitle: Text(
                            '${device.address}\n${device.supportsSpp == true ? 'Serial Port Profile' : 'Сервис проверится при подключении'}',
                          ),
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
