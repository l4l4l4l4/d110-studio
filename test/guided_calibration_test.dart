import 'package:d110_studio/media_calibration.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'calibration starts without a manual measurement form or printing',
    (tester) async {
      var prints = 0;
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showMediaCalibration(
                  context,
                  initial: MediaProfile(),
                  canPrint: true,
                  printPattern: (_) async => prints++,
                  saveProfile: (_) async => saves++,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(prints, 0);
      expect(saves, 0);
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
    },
  );
}
