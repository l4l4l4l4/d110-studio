import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:d110_studio/label.dart';
import 'package:d110_studio/qr_calibration.dart';
import 'package:d110_studio/printer.dart';
import 'package:d110_studio/media_geometry.dart';

void main() {
  test(
    'QR plan excludes rounded and offset head margins including quiet zones',
    () async {
      final media = MediaProfile(
        lengthMm: 10,
        widthMm: 9,
        radiusMm: 3,
        feedOffsetDots: 5,
        headOffsetDots: 8,
      );
      final plan = qrCalibrationPlan(media: media);
      expect(plan, isNotEmpty);
      expect(plan.length, lessThan(15));
      for (final sample in plan) {
        final document = await sample.document(media: media);
        try {
          final qr = document.elements.first;
          final bounds = Rect.fromLTWH(qr.x, qr.y, qr.width, qr.height);
          expect(media.safeRect.contains(bounds.topLeft), isTrue);
          expect(bounds.right, lessThanOrEqualTo(media.safeRect.right));
          expect(bounds.bottom, lessThanOrEqualTo(media.safeRect.bottom));
          expect(document.media.toJson(), media.toJson());
        } finally {
          document.dispose();
        }
      }
      expect(qrCalibrationPlan(media: MediaProfile(widthMm: 1)), isEmpty);
    },
  );

  testWidgets(
    'scan reports require acknowledgement and uncertain prints never replay',
    (tester) async {
      final printer = _AcknowledgedPrinter();
      addTearDown(printer.dispose);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () =>
                    showQrCalibration(context, printer, media: MediaProfile()),
                child: const Text('Open calibration'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open calibration'));
      await tester.pumpAndSettle();
      final print = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Печатать Q1'),
      );
      await tester.runAsync(print.onPressed as Future<void> Function());
      await tester.pumpAndSettle();
      final record = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Точно считан 3 из 3'),
          )
          .onPressed!;
      record();
      record();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Копировать отчёт'));
      await tester.pumpAndSettle();
      expect(
        (jsonDecode(copied!) as Map)['mediaProfile'],
        MediaProfile().toJson(),
      );
      expect((jsonDecode(copied!) as Map)['observations'], [
        allOf(containsPair('id', 'Q1'), containsPair('scan', '3/3_exact')),
      ]);
      expect(find.text('Печатать Q2'), findsOneWidget);
      printer.fail = true;
      final printSecond =
          tester
                  .widget<FilledButton>(
                    find.widgetWithText(FilledButton, 'Печатать Q2'),
                  )
                  .onPressed
              as Future<void> Function();
      await tester.runAsync(printSecond);
      await tester.pumpAndSettle();
      record();
      await tester.runAsync(printSecond);
      await tester.pumpAndSettle();
      expect(printer.rasters, 2);
      await tester.tap(find.text('Не повторять · дальше'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Копировать отчёт'));
      await tester.pumpAndSettle();
      expect((jsonDecode(copied!) as Map)['observations'], [
        allOf(containsPair('id', 'Q1'), containsPair('scan', '3/3_exact')),
        allOf(
          containsPair('id', 'Q2'),
          containsPair('scan', 'print_uncertain'),
        ),
      ]);
      expect(find.text('Печатать Q3'), findsOneWidget);
    },
  );

  testWidgets('calibration samples preserve integer modules and quiet zones', (
    tester,
  ) async {
    final samples = qrCalibrationPlan(media: MediaProfile());
    expect(
      samples.map((s) => '${s.payload}/${s.pitch}/${s.density}').toSet().length,
      15,
    );
    await tester.runAsync(() async {
      for (final sample in samples) {
        final document = await sample.document(media: MediaProfile());
        try {
          final qr = document.elements.first;
          final modules = qr.qr!.moduleCount;
          expect((qr.width / (modules + 8)).floor(), sample.pitch);
          expect(qr.height, lessThanOrEqualTo(LabelDocument.printHeadDots));
          final image = await renderDesign(document);
          try {
            final data = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            final bytes = data!.buffer.asUint8List(
              data.offsetInBytes,
              data.lengthInBytes,
            );
            int red(int x, int y) => bytes[(y * image.width + x) * 4];
            final x = qr.x.round(), y = qr.y.round(), p = sample.pitch;
            // Four-module white quiet zone, followed by a full-width finder edge.
            for (var i = 0; i < 4 * p; i++) {
              expect(red(x + i, y + 4 * p), 255);
            }
            for (var i = 0; i < 7 * p; i++) {
              expect(red(x + 4 * p + i, y + 4 * p), 0);
            }
          } finally {
            image.dispose();
          }
        } finally {
          document.dispose();
        }
      }
    });
  });
}

class _AcknowledgedPrinter extends PrinterClient {
  int rasters = 0;
  bool fail = false;

  @override
  Future<PrinterInfo> info() async =>
      const PrinterInfo(model: 'D110', firmware: 'V1.0.4', serial: 'test');

  @override
  Future<void> printRaster(
    Uint8List packed,
    int height, {
    int density = 2,
  }) async {
    rasters++;
    if (fail) throw const PrinterException('Acknowledgment lost');
  }
}
