import 'dart:async';
import 'dart:convert';

import 'package:d110_studio/label.dart';
import 'package:d110_studio/main.dart';
import 'package:d110_studio/print_quantity.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('d110_studio/device');

  for (final outcome in [
    'confirmed',
    'ambiguous',
    'failed',
    'storage failure',
    'diagnostic',
  ]) {
    testWidgets('user design history follows $outcome physical outcome', (
      tester,
    ) async {
      final old = LabelDocument(
        name: 'Previous print',
        elements: [
          LabelElement(kind: ElementKind.text, text: 'Previous', x: 16, y: 30),
        ],
      );
      old.media = old.media.copyWith(measuredAt: DateTime.utc(2026, 10, 23));
      var history = jsonEncode({'version': 1, 'document': old.toJson()});
      old.dispose();
      final originalHistory = history;
      late Completer<void> completionRequested;
      late Completer<Uint8List> completion;
      var historyWrites = 0;
      var rasterWrites = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'loadTemplates') return '[]';
        if (call.method == 'readState') {
          return (call.arguments as Map)['slot'] == 'lastPrinted'
              ? history
              : null;
        }
        if (call.method == 'writeState') {
          final args = call.arguments as Map;
          if (args['slot'] == 'lastPrinted') {
            if (outcome == 'storage failure') {
              throw PlatformException(code: 'disk_full');
            }
            historyWrites++;
            history = args['json'] as String;
          }
          return null;
        }
        if (call.method == 'write') {
          final bytes = (call.arguments as Map)['bytes'] as Uint8List;
          if (bytes.length > 8 && bytes[0] == 0x1D && bytes[1] == 0x76) {
            rasterWrites++;
          }
          return null;
        }
        if (call.method == 'exchange') {
          final bytes = (call.arguments as Map)['bytes'] as Uint8List;
          if (bytes.length == 4 && bytes[2] == 0x20) {
            return Uint8List.fromList('D110'.codeUnits);
          }
          if (bytes.length == 3 && bytes[2] == 0x40) {
            return Uint8List.fromList([0]);
          }
          if (bytes.length == 4 && bytes[2] == 0xFE && bytes[3] == 0x45) {
            completionRequested.complete();
            return completion.future;
          }
          return Uint8List.fromList([0x4F, 0x4B]);
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
      page.document.name = 'Captured design';
      page.document.elements.single.text = 'Captured before await';
      await tester.runAsync(() async {
        completionRequested = Completer<void>();
        completion = Completer<Uint8List>();
        await page.printer.connect('AA:BB:CC:DD:EE:01');
        final job = outcome == 'diagnostic'
            ? page.printer.printRaster(Uint8List(12), 1) as Future<void>
            : page.print() as Future<void>;
        if (outcome != 'diagnostic') {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(
            find.descendant(
              of: find.byType(PrintQuantityDialog),
              matching: find.text('Печатать'),
            ),
          );
          await tester.pump();
        }
        await completionRequested.future.timeout(const Duration(seconds: 10));
        expect(history, originalHistory);
        page.document.name = 'Edited while ACK pending';
        page.document.elements.single.text = 'Newer edit';
        if (outcome == 'failed') {
          completion.completeError(PlatformException(code: 'timeout'));
        } else {
          completion.complete(
            Uint8List.fromList(outcome == 'ambiguous' ? [0x01] : [0xAA]),
          );
        }
        await job;
      });
      await tester.pump();
      expect(rasterWrites, 1);
      if (outcome == 'confirmed') {
        final snapshot = (jsonDecode(history) as Map)['document'] as Map;
        expect(snapshot['name'], 'Captured design');
        expect(
          (snapshot['elements'] as List).single['text'],
          'Captured before await',
        );
        expect(historyWrites, 1);
      } else {
        expect(history, originalHistory);
        expect(historyWrites, 0);
      }
      if (outcome == 'storage failure') {
        expect(page.error, contains('не сохранён'));
        expect(page.error, contains('Не повторяйте печать'));
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
}
