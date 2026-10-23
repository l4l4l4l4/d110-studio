import 'dart:convert';

import 'package:d110_studio/label.dart';
import 'package:d110_studio/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'cold start opens the confirmed printed snapshot without printing',
    (tester) async {
      const channel = MethodChannel('d110_studio/device');
      final printed = LabelDocument(
        name: 'Printed design',
        elements: [
          LabelElement(kind: ElementKind.text, text: 'Actually printed'),
        ],
      );
      final methods = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        methods.add(call.method);
        if (call.method == 'loadTemplates') return '[]';
        if (call.method == 'readState' &&
            (call.arguments as Map)['slot'] == 'lastPrinted') {
          return jsonEncode({'version': 1, 'document': printed.toJson()});
        }
        return null;
      });
      addTearDown(() {
        printed.dispose();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
      });
      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      final paint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter is LabelPainter,
        ),
      );
      final document = (paint.painter! as LabelPainter).document;
      expect(document.name, 'Printed design');
      expect(document.elements.single.text, 'Actually printed');
      expect(methods, isNot(contains('write')));
      expect(methods, isNot(contains('exchange')));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
