import 'package:d110_studio/label.dart';
import 'package:d110_studio/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Finder control(String label) => find.byWidgetPredicate(
  (widget) => widget is NumberControl && widget.label == label,
);
Finder slider(String label) =>
    find.descendant(of: control(label), matching: find.byType(Slider));
Finder field(String label) =>
    find.descendant(of: control(label), matching: find.byType(TextField));
Finder canvasPaint() => find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.painter is LabelPainter,
);

void main() {
  Future<dynamic> openEditor(WidgetTester tester, Size viewport) async {
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
    final dynamic page = tester.state(find.byType(StudioPage));
    page.selected = page.document.elements.first;
    page.editSelected();
    await tester.pump();
    return page;
  }

  for (final viewport in [
    const Size(320, 800),
    const Size(420, 900),
    const Size(1200, 800),
  ]) {
    testWidgets('dimension drag repaints the live canvas at $viewport', (
      tester,
    ) async {
      final dynamic page = await openEditor(tester, viewport);
      final element = page.selected as LabelElement;
      final originalWidth = element.width;
      final before =
          tester.widget<CustomPaint>(canvasPaint()).painter! as LabelPainter;
      await tester.ensureVisible(slider('Ширина'));
      await tester.pump();
      expect(tester.getSize(slider('Ширина')).width, greaterThan(200));
      final gesture = await tester.startGesture(
        tester.getCenter(slider('Ширина')),
      );
      await gesture.moveBy(const Offset(25, 0));
      await tester.pump();
      expect(element.width, isNot(originalWidth));
      final during =
          tester.widget<CustomPaint>(canvasPaint()).painter! as LabelPainter;
      expect(during.revision, greaterThan(before.revision));
      expect(during.document.elements, contains(element));
      expect(
        double.parse(
          tester.widget<TextField>(field('Ширина')).controller!.text,
        ),
        closeTo(element.width, .000001),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('label-gesture')))
            .shortestSide,
        greaterThan(60),
      );
      await gesture.up();
      await tester.pump();
      await tester.ensureVisible(field('Ширина'));
      await tester.enterText(field('Ширина'), '123.125');
      await tester.pump();
      expect(element.width, closeTo(123.125, .000001));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(element.width, closeTo(123.125, .000001));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'busy inspector disables both slider and exact field, then restores them',
    (tester) async {
      final dynamic page = await openEditor(tester, const Size(420, 900));
      await tester.ensureVisible(slider('Ширина'));
      await tester.pump();
      expect(tester.widget<Slider>(slider('Ширина')).onChanged, isNotNull);
      await tester.ensureVisible(field('Ширина'));
      await tester.enterText(field('Ширина'), '123.');
      await tester.pump();
      expect(
        tester.widget<TextField>(field('Ширина')).controller!.text,
        '123.',
      );
      page.busy = true;
      page.changed();
      await tester.pump();
      expect(tester.widget<Slider>(slider('Ширина')).onChanged, isNull);
      expect(tester.widget<TextField>(field('Ширина')).enabled, isFalse);
      expect(
        tester.widget<TextField>(field('Ширина')).focusNode!.hasFocus,
        isFalse,
      );
      expect(
        double.parse(
          tester.widget<TextField>(field('Ширина')).controller!.text,
        ),
        closeTo(123, .000001),
      );
      final element = page.selected as LabelElement;
      final width = element.width;
      await tester.drag(slider('Ширина'), const Offset(30, 0));
      await tester.pump();
      expect(element.width, width);
      page.busy = false;
      page.changed();
      await tester.pump();
      expect(tester.widget<Slider>(slider('Ширина')).onChanged, isNotNull);
      expect(tester.widget<TextField>(field('Ширина')).enabled, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('media and grid sliders preserve dot and integer precision', (
    tester,
  ) async {
    final dynamic page = await openEditor(tester, const Size(320, 800));
    page.labelSettings();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(slider('Длина'));
    await tester.pump();
    final gesture = await tester.startGesture(
      tester.getCenter(slider('Длина')),
    );
    await gesture.moveBy(const Offset(15, 0));
    await tester.pump();
    final length = page.document.lengthMm as double;
    expect(length * 8, closeTo((length * 8).round(), .000001));
    expect(
      double.parse(tester.widget<TextField>(field('Длина')).controller!.text),
      length,
    );
    await gesture.up();
    await tester.pump();
    for (final label in ['Столбцы', 'Строки']) {
      await tester.ensureVisible(slider(label));
      await tester.pump();
      final grid = tester.widget<Slider>(slider(label));
      expect(grid.divisions, (grid.max - grid.min).round());
      await tester.drag(slider(label), const Offset(30, 0));
      await tester.pump();
      final value = label == 'Столбцы'
          ? page.document.columns as int
          : page.document.rows as int;
      expect(value, inInclusiveRange(1, 8));
      expect(
        double.parse(tester.widget<TextField>(field(label)).controller!.text),
        value.toDouble(),
      );
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'image parameter sliders request live raster updates before release',
    (tester) async {
      final element = LabelElement(kind: ElementKind.image);
      var rasterUpdates = 0;
      var canvasUpdates = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ElementPanel(
                element: element,
                enabled: true,
                onChanged: () => canvasUpdates++,
                onImageChanged: () => rasterUpdates++,
                onDelete: () {},
              ),
            ),
          ),
        ),
      );
      for (final label in [
        'Ширина',
        'Высота',
        'Поворот',
        'Порог',
        'Яркость',
        'Контраст',
      ]) {
        expect(slider(label), findsOneWidget);
      }
      for (final label in ['Порог', 'Яркость', 'Контраст']) {
        await tester.ensureVisible(slider(label));
        await tester.pump();
        final before = rasterUpdates;
        final gesture = await tester.startGesture(
          tester.getCenter(slider(label)),
        );
        await gesture.moveBy(const Offset(30, 0));
        await tester.pump();
        expect(rasterUpdates, greaterThan(before));
        expect(canvasUpdates, rasterUpdates);
        await gesture.up();
        await tester.pump();
      }
      expect(element.settings.threshold, isNot(128));
      expect(element.settings.brightness, isNot(0));
      expect(element.settings.contrast, isNot(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      element.dispose();
    },
  );
}
