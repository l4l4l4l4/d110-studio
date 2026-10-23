import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:d110_studio/drawing.dart';
import 'package:d110_studio/label.dart';
import 'package:d110_studio/media_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<({int width, int height, Uint8List rgba})> decodePng(
  Uint8List png,
) async {
  final codec = await ui.instantiateImageCodec(png);
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      return (
        width: frame.image.width,
        height: frame.image.height,
        rgba: Uint8List.fromList(
          data!.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        ),
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

void main() {
  testWidgets(
    'drawing masks rounded paper but exports recoverable corner ink',
    (tester) async {
      final drawing = DrawingDocument(
        width: 160,
        height: 112,
        media: MediaProfile(
          lengthMm: 10,
          widthMm: 14,
          radiusMm: 2,
          headOffsetDots: 8,
        ),
        columns: 2,
      );
      addTearDown(drawing.dispose);
      for (final point in [
        const Offset(.5, .5),
        const Offset(80.5, .5),
        const Offset(40.5, 2.5),
        const Offset(40.5, 50.5),
      ]) {
        drawing.beginStroke(1, point, 1);
        drawing.endStroke(1);
      }
      await tester.runAsync(() async {
        final source = await decodePng(await drawing.exportPng());
        expect(source.rgba[3], 255);
        expect(source.rgba[80 * 4 + 3], 255);
        expect(source.rgba[(2 * 160 + 40) * 4 + 3], 255);
        final recorder = ui.PictureRecorder();
        drawing.paintPreview(Canvas(recorder));
        final picture = recorder.endRecording();
        final preview = await picture.toImage(160, 112);
        picture.dispose();
        final pixels = await preview.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        preview.dispose();
        expect(pixels!.getUint8(3), 0);
        expect(pixels.getUint8(80 * 4 + 3), 0);
        expect(pixels.buffer.asUint8List((2 * 160 + 40) * 4, 4), [
          255,
          255,
          255,
          255,
        ]);
        expect(pixels.buffer.asUint8List((50 * 160 + 40) * 4, 4), [
          0,
          0,
          0,
          255,
        ]);
        expect((await decodePng(await drawing.exportPng())).rgba, source.rgba);
      });
    },
  );

  testWidgets(
    'one-dot taps, jitter, paths and edge marks retain physical ink',
    (tester) async {
      final drawing = DrawingDocument(width: 1600, height: 96);
      addTearDown(drawing.dispose);
      drawing.beginStroke(1, const Offset(800, 48), 1);
      drawing.extendStroke(1, const Offset(800.3, 48));
      drawing.endStroke(1);
      drawing.beginStroke(2, const Offset(810, 48), 1);
      drawing.endStroke(2);
      drawing.beginStroke(3, const Offset(820, 48), 1);
      drawing.extendStroke(3, const Offset(830.3, 48));
      drawing.endStroke(3);
      drawing.beginStroke(4, const Offset(1600, 96), 1);
      drawing.endStroke(4);
      final png = await tester.runAsync(drawing.exportPng);
      final document = LabelDocument(
        lengthMm: 100,
        columns: 2,
        elements: [
          LabelElement(
            kind: ElementKind.image,
            imageBytes: png,
            inkOnly: true,
            x: 0,
            y: 0,
            width: 1600,
            height: 96,
          ),
        ],
      );
      addTearDown(document.dispose);
      await tester.runAsync(document.elements.single.prepare);
      final raster = await tester.runAsync(() => renderTile(document, 1));
      expect(raster!.rgba[47 * 4], 0);
      expect(raster.rgba[(10 * 96 + 47) * 4], 0);
      for (var x = 20; x <= 30; x++) {
        expect(raster.rgba[(x * 96 + 47) * 4], 0);
      }
      expect(raster.rgba[799 * 96 * 4], 0);
      expect(raster.rgba.where((value) => value == 0).length, 14 * 3);
    },
  );

  test('full eight-column stack fits the bounded physical canvas', () {
    final drawing = DrawingDocument(width: 9600, height: 768);
    addTearDown(drawing.dispose);
    expect(drawing.beginStroke(1, const Offset(9599, 767), 4), isTrue);
    drawing.endStroke(1);
    expect(drawing.strokes.single.points.single, const Offset(9599, 767));
    expect(() => DrawingDocument(width: 9601, height: 10), throwsArgumentError);
    expect(
      () => DrawingDocument(width: 9600, height: 9600),
      throwsArgumentError,
    );
  });

  test('cancelled and secondary pointers preserve committed strokes', () {
    final drawing = DrawingDocument(width: 100, height: 50);
    addTearDown(drawing.dispose);
    expect(drawing.beginStroke(1, const Offset(10, 10), 4), isTrue);
    drawing.endStroke(1);
    drawing.beginStroke(2, const Offset(20, 20), 8);
    expect(drawing.beginStroke(3, const Offset(30, 30), 2), isFalse);
    drawing.cancelStroke(3);
    expect(drawing.isDrawing, isTrue);
    drawing.cancelStroke(2);
    expect(drawing.strokes, hasLength(1));
    expect(drawing.strokes.single.points, [const Offset(10, 10)]);
    expect(drawing.isDrawing, isFalse);
    drawing.undo();
    expect(drawing.isBlank, isTrue);
  });

  test('clear can be undone including after a cancelled new stroke', () {
    final drawing = DrawingDocument(width: 100, height: 50);
    addTearDown(drawing.dispose);
    drawing.beginStroke(1, const Offset(10, 10), 4);
    drawing.endStroke(1);
    drawing.clear();
    expect(drawing.isBlank, isTrue);
    expect(drawing.canUndo, isTrue);
    drawing.beginStroke(2, const Offset(20, 20), 3);
    drawing.cancelStroke(2);
    drawing.undo();
    expect(drawing.strokes.single.points.single, const Offset(10, 10));
    drawing.beginStroke(3, const Offset(30, 20), 2);
    drawing.endStroke(3);
    drawing.undo();
    expect(drawing.strokes, hasLength(1));
  });

  test('point and stroke limits retain undo and bound memory', () {
    final drawing = DrawingDocument(
      width: 100,
      height: 50,
      maxPoints: 3,
      maxStrokes: 2,
    );
    addTearDown(drawing.dispose);
    drawing.beginStroke(1, const Offset(1, 1), 2);
    drawing.extendStroke(1, const Offset(2, 2));
    drawing.extendStroke(1, const Offset(3, 3));
    drawing.extendStroke(1, const Offset(4, 4));
    drawing.endStroke(1);
    expect(drawing.strokes.single.points, hasLength(3));
    expect(drawing.limitReached, isTrue);
    expect(drawing.beginStroke(2, const Offset(5, 5), 2), isFalse);
    drawing.clear();
    expect(drawing.beginStroke(3, const Offset(6, 6), 2), isTrue);
    drawing.endStroke(3);
    drawing.beginStroke(4, const Offset(7, 7), 2);
    drawing.endStroke(4);
    expect(drawing.beginStroke(5, const Offset(8, 8), 2), isFalse);
    drawing.undo();
    expect(drawing.beginStroke(6, const Offset(9, 9), 2), isTrue);
  });

  test('physical coordinate mapping is independent of viewport scale', () {
    expect(
      drawingPoint(const Offset(160, 60), const Size(320, 160), 80, 40),
      const Offset(40, 15),
    );
    expect(
      drawingPoint(const Offset(40, 15), const Size(80, 40), 80, 40),
      const Offset(40, 15),
    );
  });

  testWidgets(
    'PNG exports exact dimensions, black dots and transparent paper',
    (tester) async {
      final drawing = DrawingDocument(width: 32, height: 16);
      addTearDown(drawing.dispose);
      drawing.beginStroke(1, const Offset(8, 8), 6);
      drawing.endStroke(1);
      final first = await tester.runAsync(drawing.exportPng);
      final second = await tester.runAsync(drawing.exportPng);
      expect(first, orderedEquals(second!));
      final decoded = await tester.runAsync(() => decodePng(first!));
      expect((decoded!.width, decoded.height), (32, 16));
      final center = (8 * 32 + 8) * 4;
      expect(decoded.rgba.sublist(center, center + 4), [0, 0, 0, 255]);
      expect(decoded.rgba[3], 0);
      expect(decoded.rgba[(15 * 32 + 31) * 4 + 3], 0);
      expect(decoded.rgba[(8 * 32 + 4) * 4 + 3], 0);
      expect(decoded.rgba[(8 * 32 + 11) * 4 + 3], 0);
    },
  );

  testWidgets('cancelled active ink is absent from exported pixels', (
    tester,
  ) async {
    final drawing = DrawingDocument(width: 32, height: 16);
    addTearDown(drawing.dispose);
    drawing.beginStroke(1, const Offset(4, 4), 4);
    drawing.endStroke(1);
    drawing.beginStroke(2, const Offset(24, 12), 4);
    drawing.extendStroke(2, const Offset(28, 12));
    drawing.cancelStroke(2);
    final png = await tester.runAsync(drawing.exportPng);
    final decoded = await tester.runAsync(() => decodePng(png!));
    expect(decoded!.rgba[(4 * 32 + 4) * 4 + 3], 255);
    expect(decoded.rgba[(12 * 32 + 24) * 4 + 3], 0);
    expect(decoded.rgba[(12 * 32 + 28) * 4 + 3], 0);
  });

  testWidgets('off-paper input is clipped without edge-clamped trails', (
    tester,
  ) async {
    final drawing = DrawingDocument(width: 20, height: 20);
    addTearDown(drawing.dispose);
    expect(drawing.beginStroke(0, const Offset(-4, 4), 2), isFalse);
    drawing.beginStroke(1, const Offset(10, 10), 2);
    drawing.extendStroke(1, const Offset(30, 10));
    drawing.extendStroke(1, const Offset(30, 19));
    drawing.endStroke(1);
    final png = await tester.runAsync(drawing.exportPng);
    final decoded = await tester.runAsync(() => decodePng(png!));
    expect(decoded!.rgba[(10 * 20 + 19) * 4 + 3], 255);
    expect(decoded.rgba[(18 * 20 + 19) * 4 + 3], 0);
  });

  for (final viewport in [const Size(420, 900), const Size(1200, 800)]) {
    testWidgets('editor draws, adjusts width, clears and saves at $viewport', (
      tester,
    ) async {
      tester.view.physicalSize = viewport;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final completion = Completer<Uint8List?>();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  completion.complete(
                    await showDrawingEditor(context, width: 80, height: 40),
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
      final save = find.widgetWithText(FilledButton, 'Сохранить');
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(viewport.height));
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      final slider = find.byType(Slider);
      await tester.tapAt(tester.getCenter(slider) + const Offset(30, 0));
      await tester.pumpAndSettle();
      final surface = find.byKey(const ValueKey('drawing-paper'));
      final size = tester.getSize(surface);
      expect(size.width / size.height, closeTo(2, 0.001));
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(20, 10));
      await gesture.up();
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
      await tester.tap(find.byTooltip('Очистить рисунок'));
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.tap(find.byTooltip('Отменить последнее действие'));
      await tester.pump();
      final onSave =
          tester.widget<FilledButton>(save).onPressed!
              as Future<void> Function();
      await tester.runAsync(onSave);
      await tester.pumpAndSettle();
      final result = await completion.future;
      expect(result, isNotNull);
      final decoded = await tester.runAsync(() => decodePng(result!));
      expect((decoded!.width, decoded.height), (80, 40));
      final center = (20 * 80 + 40) * 4;
      expect(decoded.rgba.sublist(center, center + 4), [0, 0, 0, 255]);
      expect(decoded.rgba[3], 0);
    });
  }

  testWidgets(
    'pointer cancellation and viewport changes discard only new ink',
    (tester) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDrawingEditor(context, width: 80, height: 40),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final surface = find.byKey(const ValueKey('drawing-paper'));
      final save = find.widgetWithText(FilledButton, 'Сохранить');
      final cancelled = await tester.startGesture(tester.getCenter(surface));
      await cancelled.moveBy(const Offset(20, 0));
      await cancelled.cancel();
      await tester.pump();
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.tap(surface);
      await tester.pump();
      final resized = await tester.startGesture(tester.getCenter(surface));
      await resized.moveBy(const Offset(20, 0));
      tester.view.physicalSize = const Size(900, 420);
      await tester.pumpAndSettle();
      await resized.up();
      await tester.pump();
      await tester.tap(find.byTooltip('Отменить последнее действие'));
      await tester.pump();
      // A single undo removes the original dot: resize did not commit a stroke.
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('explicit cancel returns null after drawing', (tester) async {
    Uint8List? result = Uint8List(1);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showDrawingEditor(context, width: 80, height: 40);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('drawing-paper')));
    await tester.pump();
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
