import 'dart:async';
import 'dart:convert';

import 'package:d110_studio/label.dart';
import 'package:d110_studio/main.dart';
import 'package:d110_studio/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('d110_studio/device');
  late Map<String, String> disk;
  late List<String> methods;
  setUp(() {
    disk = {};
    methods = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methods.add(call.method);
          if (call.method == 'loadTemplates') return '[]';
          if (call.method == 'readState') {
            return disk[(call.arguments as Map)['slot']];
          }
          if (call.method == 'writeState') {
            final args = call.arguments as Map;
            disk[args['slot'] as String] = args['json'] as String;
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  testWidgets(
    'orientation preference survives editing, keyboard and relaunch',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final paint = find.byWidgetPredicate(
        (widget) => widget is CustomPaint && widget.painter is LabelPainter,
      );
      void expectDirection(bool vertical) {
        final box = tester.renderObject<RenderBox>(paint);
        final direction =
            box.localToGlobal(const Offset(1, 0)) -
            box.localToGlobal(Offset.zero);
        expect(vertical ? direction.dx : direction.dy, closeTo(0, .001));
        expect(vertical ? direction.dy : direction.dx, greaterThan(0));
      }

      Future<void> orientation(String label) async {
        final dynamic page = tester.state(find.byType(StudioPage));
        page.labelSettings();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text(label));
        await tester.pump();
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<void> relaunch() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        await tester.pumpWidget(const StudioApp());
        await tester.pump();
      }

      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      expectDirection(false);
      final dynamic page = tester.state(find.byType(StudioPage));
      final design = jsonEncode((page.document as LabelDocument).toJson());
      await orientation('Вертикально');
      expectDirection(true);
      expect(jsonEncode((page.document as LabelDocument).toJson()), design);
      await relaunch();
      expectDirection(true);
      final dynamic reopened = tester.state(find.byType(StudioPage));
      reopened.editSelected();
      await tester.pump();
      expectDirection(true);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expectDirection(true);
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.tap(find.byTooltip('Закрыть настройки'));
      await tester.pump();
      expectDirection(true);
      await orientation('Горизонтально');
      await relaunch();
      expectDirection(false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'new named tab switches without inspector or document state bleed',
    (tester) async {
      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      final dynamic page = tester.state(find.byType(StudioPage));
      final original = page.document as LabelDocument;
      final workspace = page.workspace as DesignWorkspace;
      final firstId = workspace.activeId;
      page.editSelected();
      await tester.pump();
      expect(find.byKey(const ValueKey('live-inspector')), findsOneWidget);
      await tester.tap(find.byTooltip('Новый макет'));
      await tester.pump();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Second design',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(workspace.tabs, hasLength(2));
      expect(page.document.name, 'Second design');
      expect(page.selected, isNull);
      expect(find.byKey(const ValueKey('live-inspector')), findsNothing);
      expect(identical(page.document, original), isFalse);
      page.activateTab(firstId);
      await tester.pump();
      expect(identical(page.document, original), isTrue);
      expect(find.byKey(const ValueKey('live-inspector')), findsOneWidget);
      expect(page.connection.printer, same(page.printer));
      await tester.pump(const Duration(milliseconds: 250));
      expect(disk['workspace'], isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'active tab keeps its close button visible after create and switch',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      final dynamic page = tester.state(find.byType(StudioPage));
      final workspace = page.workspace as DesignWorkspace;
      final firstId = workspace.activeId;
      void expectVisibleClose() {
        final close = find.byKey(ValueKey('close-${workspace.activeId}'));
        final viewport = find
            .ancestor(of: close, matching: find.byType(SingleChildScrollView))
            .first;
        final visible = tester.getRect(viewport);
        final button = tester.getRect(close);
        expect(button.left, greaterThanOrEqualTo(visible.left));
        expect(button.right, lessThanOrEqualTo(visible.right));
        expect(close.hitTestable(), findsOneWidget);
      }

      for (var index = 0; index < 3; index++) {
        unawaited(page.newDesign() as Future<void>);
        await tester.pump();
        await tester.enterText(
          find.byType(TextField),
          'Long independent design $index',
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        expectVisibleClose();
      }
      page.activateTab(firstId);
      await tester.pump();
      await tester.pump();
      expectVisibleClose();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('safe close cancellation keeps changed draft open', (
    tester,
  ) async {
    await tester.pumpWidget(const StudioApp());
    await tester.pump();
    final dynamic page = tester.state(find.byType(StudioPage));
    final workspace = page.workspace as DesignWorkspace;
    page.document.name = 'Unsaved';
    page.changed();
    final id = workspace.activeId;
    unawaited(page.closeDesign(id) as Future<void>);
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Оставить'));
    await tester.pump();
    expect(workspace.tabs.single.id, id);
    expect(page.document.name, 'Unsaved');
    expect(workspace.active.dirty, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'restored drafts survive while startup selects last print without sending data',
    (tester) async {
      final doc = LabelDocument(
        name: 'Printed',
        elements: [LabelElement(kind: ElementKind.text, text: 'Confirmed ink')],
      );
      final printed = doc.toJson();
      final drafts = DesignWorkspace(doc);
      drafts.active.document.elements.single.text = 'Newer draft';
      drafts.active.dirty = true;
      disk['workspace'] = jsonEncode(drafts.toJson());
      disk['lastPrinted'] = jsonEncode({'version': 1, 'document': printed});
      drafts.dispose();
      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      final dynamic page = tester.state(find.byType(StudioPage));
      final workspace = page.workspace as DesignWorkspace;
      expect(workspace.tabs, hasLength(2));
      expect(page.document.elements.single.text, 'Confirmed ink');
      expect(workspace.tabs.first.document.elements.single.text, 'Newer draft');
      expect(methods, isNot(contains('write')));
      expect(methods, isNot(contains('exchange')));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'slow persistence cannot overwrite a newer draft with an older snapshot',
    (tester) async {
      final firstWrite = Completer<void>();
      final snapshots = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'loadTemplates') return '[]';
        if (call.method == 'writeState' &&
            (call.arguments as Map)['slot'] == 'workspace') {
          final snapshot = (call.arguments as Map)['json'] as String;
          snapshots.add(snapshot);
          if (snapshots.length == 1) await firstWrite.future;
          disk['workspace'] = snapshot;
        }
        return null;
      });
      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(snapshots, hasLength(1));
      final dynamic page = tester.state(find.byType(StudioPage));
      page.document.name = 'Newest draft';
      page.changed();
      await tester.pump(const Duration(milliseconds: 250));
      expect(snapshots, hasLength(1));
      firstWrite.complete();
      await tester.pump();
      expect(snapshots, hasLength(2));
      final state = jsonDecode(disk['workspace']!) as Map;
      expect(
        (state['tabs'] as List).single['document']['name'],
        'Newest draft',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'corrupt drafts surface a persistent error and are never overwritten',
    (tester) async {
      disk['workspace'] = '{broken';
      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      final dynamic page = tester.state(find.byType(StudioPage));
      page.document.name = 'Changed';
      page.changed();
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('не будут перезаписаны'), findsOneWidget);
      expect(disk['workspace'], '{broken');
      await tester.pumpWidget(const SizedBox());
      expect(disk['workspace'], '{broken');
    },
  );
  testWidgets(
    'corrupt print history does not block valid draft restoration or saving',
    (tester) async {
      final drafts = DesignWorkspace(
        LabelDocument(
          name: 'Recoverable draft',
          elements: [LabelElement(kind: ElementKind.text, text: 'Unsaved ink')],
        ),
      );
      drafts.active.dirty = true;
      disk['workspace'] = jsonEncode(drafts.toJson());
      drafts.dispose();
      const corrupt = '{"version":1,"document":{}}';
      disk['lastPrinted'] = corrupt;
      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      final dynamic page = tester.state(find.byType(StudioPage));
      expect(page.document.name, 'Recoverable draft');
      expect(page.document.elements.single.text, 'Unsaved ink');
      expect(page.workspace.active.dirty, isTrue);
      page.document.name = 'Recovered and edited';
      page.changed();
      await tester.pump(const Duration(milliseconds: 250));
      final stored = jsonDecode(disk['workspace']!) as Map;
      expect(
        (stored['tabs'] as List).single['document']['name'],
        'Recovered and edited',
      );
      expect(disk['lastPrinted'], corrupt);
      expect(methods, isNot(contains('exchange')));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
