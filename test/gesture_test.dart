import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:d110_studio/label.dart';
import 'package:d110_studio/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Finder labelPaint() => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is LabelPainter,
);
Finder gestureSurface() => find.byKey(const ValueKey('label-gesture'));

Future<LabelPainter> openEditor(WidgetTester tester, Size viewport) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  const channel = MethodChannel('d110_studio/device');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    channel,
    (call) async => call.method == 'loadTemplates' ? '[]' : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    ),
  );
  await tester.pumpWidget(const StudioApp());
  await tester.pump();
  return tester.widget<CustomPaint>(labelPaint()).painter! as LabelPainter;
}

/// Screen point of a label-space corner, taken from the rendered surface so
/// portrait rotation and centering cannot drift from the widget.
Offset rendered(RenderBox box, LabelPainter painter, Offset labelPoint) {
  final paint = find.byWidgetPredicate(
    (widget) =>
        widget is CustomPaint &&
        widget.painter is LabelPainter &&
        (widget.painter! as LabelPainter).document == painter.document,
  );
  final paintBox = paint.evaluate().single.renderObject! as RenderBox;
  final current =
      (paint.evaluate().single.widget as CustomPaint).painter! as LabelPainter;
  return paintBox.localToGlobal(labelPoint * current.scale);
}

void main() {
  testWidgets('saving text survives dialog dismissal and keeps its payload', (
    tester,
  ) async {
    final painter = await openEditor(tester, const Size(1000, 700));
    await tester.tap(find.text('Текст'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'Saved label');
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(painter.document.elements.last.text, 'Saved label');
    await tester.tap(find.text('QR'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'https://example.com/saved');
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(painter.document.elements.last.kind, ElementKind.qr);
    expect(painter.document.elements.last.text, 'https://example.com/saved');
    await tester.pumpWidget(const SizedBox());
  });

  for (final dismiss in ['cancel', 'barrier']) {
    testWidgets('$dismiss discards text and lets the next dialog save', (
      tester,
    ) async {
      final painter = await openEditor(tester, const Size(1000, 700));
      final original = List<LabelElement>.of(painter.document.elements);
      await tester.tap(find.text('Текст'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextField), 'Discarded label');
      if (dismiss == 'cancel') {
        await tester.tap(find.text('Отмена'));
      } else {
        await tester.tapAt(const Offset(10, 10));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(painter.document.elements, orderedEquals(original));
      await tester.tap(find.text('Текст'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Новый текст',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(painter.document.elements.last.text, 'Новый текст');
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final portrait in [true, false]) {
    testWidgets(
      'resize handle accepts its visible outside-paper half in ${portrait ? 'portrait' : 'landscape'}',
      (tester) async {
        final painter = await openEditor(
          tester,
          portrait ? const Size(420, 900) : const Size(1000, 700),
        );
        final element = painter.document.elements.first;
        element.x = 0;
        element.y = 0;
        element.width = painter.document.width.toDouble();
        element.height = LabelDocument.height.toDouble();
        final dynamic page = tester.state(find.byType(StudioPage));
        page.changed();
        await tester.pump();
        final box = tester.renderObject<RenderBox>(gestureSurface());
        final width = element.width;
        final height = element.height;
        final corner = rendered(box, painter, Offset(width, height));
        final outside = corner + const Offset(8, 8);
        final gesture = await tester.startGesture(
          outside,
          kind: ui.PointerDeviceKind.touch,
        );
        await gesture.moveBy(const Offset(40, 20));
        await gesture.moveBy(const Offset(20, 10));
        await gesture.up();
        await tester.pump();
        expect(element.width, greaterThan(width));
        expect(element.height, greaterThan(height));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final angle in [0.0, .65]) {
    testWidgets('repeated resize keeps current touch geometry at $angle', (
      tester,
    ) async {
      var painter = await openEditor(tester, const Size(1000, 700));
      final element = painter.document.elements.first;
      element.rotation = angle;
      final dynamic page = tester.state(find.byType(StudioPage));
      page.changed();
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        painter =
            tester.widget<CustomPaint>(labelPaint()).painter! as LabelPainter;
        final box = tester.renderObject<RenderBox>(gestureSurface());
        final center = Offset(
          element.x + element.width / 2,
          element.y + element.height / 2,
        );
        final corner =
            center +
            Offset(
              element.width / 2 * math.cos(angle) -
                  element.height / 2 * math.sin(angle),
              element.width / 2 * math.sin(angle) +
                  element.height / 2 * math.cos(angle),
            );
        final width = element.width;
        final desired = rendered(box, painter, corner);
        final viewport = tester.getRect(gestureSurface());
        final visibleKnob = Offset(
          desired.dx.clamp(viewport.left + 16, viewport.right - 16),
          desired.dy.clamp(viewport.top + 16, viewport.bottom - 16),
        );
        final gesture = await tester.startGesture(
          visibleKnob,
          kind: ui.PointerDeviceKind.touch,
        );
        final delta = Offset(math.cos(angle), math.sin(angle)) * 34;
        await gesture.moveBy(delta);
        await gesture.moveBy(delta);
        await gesture.up();
        await tester.pump();
        expect(element.width, greaterThan(width), reason: 'gesture $i');
        expect(element.rotation, closeTo(angle, .0001));
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('tiny rotated object chooses the nearest overlapping knob', (
    tester,
  ) async {
    var painter = await openEditor(tester, const Size(1000, 700));
    final element = painter.document.elements.first;
    element
      ..width = 8
      ..height = 5
      ..rotation = .4;
    final dynamic page = tester.state(find.byType(StudioPage));
    page.changed();
    await tester.pump();
    painter = tester.widget<CustomPaint>(labelPaint()).painter! as LabelPainter;
    final box = tester.renderObject<RenderBox>(gestureSurface());
    final center = Offset(element.x + 4, element.y + 2.5);
    final corner =
        center +
        Offset(
          4 * math.cos(.4) - 2.5 * math.sin(.4),
          4 * math.sin(.4) + 2.5 * math.cos(.4),
        );
    final gesture = await tester.startGesture(
      rendered(box, painter, corner),
      kind: ui.PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(30, 20));
    await gesture.moveBy(const Offset(20, 10));
    await gesture.up();
    await tester.pump();
    expect(element.width, greaterThan(8));
    expect(element.rotation, closeTo(.4, .0001));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('resize captures finger-down before the touch slop is crossed', (
    tester,
  ) async {
    final painter = await openEditor(tester, const Size(420, 900));
    final element = painter.document.elements.first;
    final box = tester.renderObject<RenderBox>(gestureSurface());
    final width = element.width;
    final height = element.height;
    final center = Offset(element.x + width / 2, element.y + height / 2);
    final corner = rendered(
      box,
      painter,
      Offset(element.x + width, element.y + height),
    );
    final gesture = await tester.startGesture(
      corner,
      kind: ui.PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(40, 24));
    await gesture.moveBy(const Offset(20, 12));
    await gesture.up();
    await tester.pump();
    expect(element.width, greaterThan(width));
    expect(element.height, greaterThan(height));
    expect(element.x + element.width / 2, closeTo(center.dx, .001));
    expect(element.y + element.height / 2, closeTo(center.dy, .001));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('rotation captures finger-down instead of dragging the box', (
    tester,
  ) async {
    final painter = await openEditor(tester, const Size(420, 900));
    final element = painter.document.elements.first;
    final box = tester.renderObject<RenderBox>(gestureSurface());
    final x = element.x;
    final y = element.y;
    final width = element.width;
    final height = element.height;
    final corner = rendered(box, painter, Offset(x, y));
    final gesture = await tester.startGesture(
      corner,
      kind: ui.PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(0, 40));
    await gesture.moveBy(const Offset(0, 40));
    await gesture.up();
    await tester.pump();
    expect(element.rotation.abs(), greaterThan(.1));
    expect(element.x, x);
    expect(element.y, y);
    expect(element.width, width);
    expect(element.height, height);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('two fingers zoom the label without resizing the object', (
    tester,
  ) async {
    final painter = await openEditor(tester, const Size(420, 900));
    final element = painter.document.elements.first;
    final width = element.width;
    final box = tester.renderObject<RenderBox>(gestureSurface());
    final center = box.localToGlobal(box.size.center(Offset.zero));
    final left = await tester.startGesture(
      center - const Offset(24, 0),
      kind: ui.PointerDeviceKind.touch,
    );
    final right = await tester.startGesture(
      center + const Offset(24, 0),
      kind: ui.PointerDeviceKind.touch,
    );
    await left.moveTo(center - const Offset(90, 0));
    await right.moveTo(center + const Offset(90, 0));
    await left.up();
    await right.up();
    await tester.pump();
    final zoomed =
        tester.widget<CustomPaint>(labelPaint()).painter! as LabelPainter;
    expect(zoomed.scale, greaterThan(painter.scale * 1.4));
    expect(element.width, width);
    expect(find.textContaining('Перетащите'), findsNothing);
    expect(find.textContaining('Белое'), findsNothing);
    expect(find.textContaining('Вид +90'), findsNothing);
    expect(find.text('Печатать'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
