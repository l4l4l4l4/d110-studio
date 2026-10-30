import 'dart:convert';

import 'package:d110_studio/drawing.dart';
import 'package:d110_studio/label.dart';
import 'package:d110_studio/main.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'finishing a measured length field without typing preserves its exact calibration',
    (tester) async {
      const channel = MethodChannel('d110_studio/device');
      final printed = LabelDocument(
        media: MediaProfile(
          lengthMm: 30.125,
          widthMm: 12.25,
          radiusMm: 1.75,
          measuredAt: DateTime.utc(2026, 10, 23),
        ),
        elements: [
          LabelElement(kind: ElementKind.text, text: 'Measured artwork'),
        ],
      );
      final history = jsonEncode({'version': 1, 'document': printed.toJson()});
      printed.dispose();
      final currentRoll = jsonEncode(
        MediaProfile(
          lengthMm: 40,
          widthMm: 14,
          radiusMm: 2,
          measuredAt: DateTime.utc(2026, 10, 24),
        ).toJson(),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'loadTemplates') return '[]';
        if (call.method == 'readState') {
          return switch ((call.arguments as Map)['slot']) {
            'lastPrinted' => history,
            'mediaProfile' => currentRoll,
            _ => null,
          };
        }
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(const StudioApp());
      await tester.pump();
      final dynamic page = tester.state(find.byType(StudioPage));
      expect(page.document.lengthMm, 30.125);
      page.labelSettings();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final length = find.byWidgetPredicate(
        (widget) => widget is NumberControl && widget.label == 'Длина',
      );
      final field = find.descendant(
        of: length,
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(page.document.lengthMm, 30.125);
      expect(page.document.media.isCalibrated, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('corrupt history does not replace the saved physical roll', (
    tester,
  ) async {
    const channel = MethodChannel('d110_studio/device');
    final profile = MediaProfile(
      lengthMm: 40,
      widthMm: 14,
      radiusMm: 2,
      measuredAt: DateTime.utc(2026, 10, 23),
    );
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      if (call.method == 'loadTemplates') return '[]';
      if (call.method == 'readState') {
        return switch ((call.arguments as Map)['slot']) {
          'lastPrinted' => '{"version":1,"document":{}}',
          'mediaProfile' => jsonEncode(profile.toJson()),
          _ => null,
        };
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    await tester.pumpWidget(const StudioApp());
    await tester.pump();
    final dynamic page = tester.state(find.byType(StudioPage));
    expect(page.document.media.toJson(), profile.toJson());
    await tester.pumpWidget(const SizedBox());
  });
  for (final (name, radius, offset) in [
    ('rounded corners', 6.0, 0),
    ('feed offset', 1.0, 160),
  ]) {
    testWidgets('invalid length preserves the calibrated $name profile', (
      tester,
    ) async {
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
      final profile = MediaProfile(
        radiusMm: radius,
        feedOffsetDots: offset,
        measuredAt: DateTime.utc(2026, 10, 23),
      );
      page.document.media = profile;
      page.labelSettings();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final length = find.byWidgetPredicate(
        (widget) => widget is NumberControl && widget.label == 'Длина',
      );
      final field = find.descendant(
        of: length,
        matching: find.byType(TextField),
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, '10');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(page.document.media, same(profile));
      expect(find.byKey(const ValueKey('media-edit-error')), findsOneWidget);
      await tester.enterText(field, '31');
      await tester.pump();
      expect(page.document.lengthMm, 31);
      expect(page.document.media.radiusMm, radius);
      expect(page.document.media.feedOffsetDots, offset);
      expect(find.byKey(const ValueKey('media-edit-error')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('tall ink grows and survives submitting its height unchanged', (
    tester,
  ) async {
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
    final media = MediaProfile(widthMm: 150);
    final drawing = DrawingDocument(
      width: 240,
      height: 3600,
      media: media,
      rows: 3,
    );
    drawing.beginStroke(1, const Offset(120, 50), 2);
    drawing.endStroke(1);
    final png = await tester.runAsync(drawing.exportPng);
    drawing.dispose();
    final ink = LabelElement(
      kind: ElementKind.image,
      imageBytes: png!,
      inkOnly: true,
      width: 240,
      height: 3600,
    );
    await tester.runAsync(ink.prepare);
    page.document.media = media;
    page.document.rows = 3;
    page.document.elements
      ..clear()
      ..add(ink);
    page.selected = ink;
    page.changed();
    await tester.pump();
    page.editSelected();
    await tester.pump();
    final height = find.byWidgetPredicate(
      (widget) => widget is NumberControl && widget.label == 'Высота',
    );
    final field = find.descendant(of: height, matching: find.byType(TextField));
    await tester.ensureVisible(field);
    await tester.enterText(field, '3960');
    await tester.pump();
    expect(ink.height, closeTo(3960, .000001));
    expect(ink.width, closeTo(264, .000001));
    await tester.tap(field);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(ink.height, closeTo(3960, .000001));
    expect(ink.width, closeTo(264, .000001));
    await tester.pumpWidget(const SizedBox());
  });
}
