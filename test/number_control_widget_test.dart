import 'package:d110_studio/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    double initial = 30.125,
    double min = 10,
    double max = 150,
    double step = .125,
    bool enabled = true,
    ValueChanged<double>? changed,
  }) async {
    var value = initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => SizedBox(
              width: 288,
              child: NumberControl(
                label: 'Длина',
                suffix: 'мм',
                value: value,
                min: min,
                max: max,
                step: step,
                onChanged: enabled
                    ? (next) {
                        update(() => value = next);
                        changed?.call(next);
                      }
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'drag updates the labeled value before release at dot precision',
    (tester) async {
      final values = <double>[];
      await mount(tester, changed: values.add);
      expect(find.text('Длина'), findsOneWidget);
      expect(find.text('мм'), findsWidgets);
      expect(find.byIcon(Icons.add), findsNothing);
      expect(find.byIcon(Icons.remove), findsNothing);
      final slider = find.byType(Slider);
      final center = tester.getCenter(slider);
      final gesture = await tester.startGesture(center);
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(values, isNotEmpty);
      final duringDrag = values.last;
      expect(duringDrag, greaterThan(30.125));
      expect(duringDrag * 8, closeTo((duringDrag * 8).round(), .000001));
      expect(
        double.parse(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
        ),
        duringDrag,
      );
      await gesture.up();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard adjusts one physical dot without rounding manual input',
    (tester) async {
      final values = <double>[];
      await mount(tester, changed: values.add);
      final field = find.byType(TextField);
      await tester.enterText(field, '30,375');
      await tester.pump();
      expect(values.last, 30.375);
      expect(tester.widget<TextField>(field).controller!.text, '30,375');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '30.375');
      tester.widget<Slider>(find.byType(Slider)).focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(values.last, 30.5);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(values.last, 30.375);
      await tester.enterText(field, '30.0625');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(values.last, 30.0625);
      expect(tester.widget<TextField>(field).controller!.text, '30.0625');
    },
  );

  testWidgets(
    'invalid entry restores the value and submitted limits still clamp',
    (tester) async {
      final values = <double>[];
      await mount(tester, changed: values.add);
      final field = find.byType(TextField);
      for (final invalid in ['-', 'NaN', 'Infinity']) {
        await tester.enterText(field, invalid);
        await tester.pump();
        expect(values, isEmpty);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(tester.widget<TextField>(field).controller!.text, '30.125');
      }
      await tester.enterText(field, '999');
      await tester.pump();
      expect(values, isEmpty);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(values.last, 150);
      expect(tester.widget<TextField>(field).controller!.text, '150');
      await tester.enterText(field, '');
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(Slider)),
      );
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      expect(
        double.parse(tester.widget<TextField>(field).controller!.text),
        values.last,
      );
      await gesture.up();
    },
  );

  testWidgets('disabled and single-value ranges cannot mutate', (tester) async {
    final values = <double>[];
    await mount(tester, enabled: false, changed: values.add);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();
    expect(values, isEmpty);
    await mount(tester, initial: 10, min: 10, max: 10, changed: values.add);
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'large dimensions use a stable drag window and retain exact entry',
    (tester) async {
      final values = <double>[];
      await mount(
        tester,
        initial: 3960,
        min: 1,
        max: 9600,
        step: 1,
        changed: values.add,
      );
      final slider = find.byType(Slider);
      final before = tester.widget<Slider>(slider);
      expect(before.max - before.min, 1024);
      expect(before.min, lessThan(3960));
      expect(before.max, greaterThan(3960));
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      final firstValue = values.last;
      final firstMove = tester.widget<Slider>(slider);
      expect(firstMove.min, before.min);
      expect(firstMove.max, before.max);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      expect(values.last, greaterThan(firstValue));
      expect(tester.widget<Slider>(slider).min, before.min);
      await gesture.up();
      await tester.pump();
      final field = find.byType(TextField);
      await tester.enterText(field, '9000.125');
      await tester.pump();
      expect(values.last, 9000.125);
      final moved = tester.widget<Slider>(slider);
      expect(moved.min, lessThan(9000.125));
      expect(moved.max, greaterThan(9000.125));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, '9000.125');
    },
  );
}
