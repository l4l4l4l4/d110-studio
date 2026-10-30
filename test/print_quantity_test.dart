import 'package:d110_studio/print_quantity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'invalid counts cannot submit and stacked copies show total paper use',
    (tester) async {
      int? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<int>(
                    context: context,
                    builder: (_) =>
                        const PrintQuantityDialog(tilesPerDesign: 4),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('print-copies'));
      for (final invalid in ['', '0', '-1', '100', '1.5', 'abc']) {
        await tester.enterText(field, invalid);
        await tester.pump();
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
      }
      await tester.enterText(field, '3');
      await tester.pump();
      expect(find.text('12 наклеек · 4 на копию'), findsOneWidget);
      await tester.tap(find.text('Печатать'));
      await tester.pumpAndSettle();
      expect(result, 3);
      expect(tester.takeException(), isNull);
    },
  );
}
