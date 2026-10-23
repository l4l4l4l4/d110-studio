import 'dart:convert';

import 'package:d110_studio/app_state_store.dart';
import 'package:d110_studio/label.dart';
import 'package:d110_studio/last_printed.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/printed-state');
  late Map<String, String> files;
  var writes = 0;
  var failWrite = false;
  setUp(() {
    files = {};
    writes = 0;
    failWrite = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = call.arguments as Map;
          if (call.method == 'readState') return files[args['slot']];
          if (failWrite) throw PlatformException(code: 'disk_full');
          writes++;
          files[args['slot'] as String] = args['json'] as String;
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('confirmed tile stores original full design only once', () async {
    final history = LastPrintedHistory(AppStateStore(channel: channel));
    final document = LabelDocument(
      name: 'Original',
      rows: 2,
      elements: [LabelElement(kind: ElementKind.text, text: 'Before await')],
    );
    final job = LastPrintedJob.capture(document, history);
    document.name = 'Edited while waiting';
    document.elements.single.text = 'After await';
    expect(
      files,
      isEmpty,
    ); // Failed, cancelled or ambiguous jobs never confirm.
    expect(await job.confirmed(), isNull);
    expect(await job.confirmed(), isNull);
    final restored = await history.restore();
    expect(restored!.name, 'Original');
    expect(restored.rows, 2);
    expect(restored.elements.single.text, 'Before await');
    expect(writes, 1);
    restored.dispose();
    document.dispose();
  });

  test(
    'failed or ambiguous unconfirmed job leaves earlier history intact',
    () async {
      final history = LastPrintedHistory(AppStateStore(channel: channel));
      final old = LabelDocument(name: 'Already printed');
      await LastPrintedJob.capture(old, history).confirmed();
      final next = LabelDocument(name: 'Ambiguous');
      LastPrintedJob.capture(next, history);
      final restored = await history.restore();
      expect(restored!.name, 'Already printed');
      expect(writes, 1);
      restored.dispose();
      old.dispose();
      next.dispose();
    },
  );

  test(
    'post-ack storage failure is not a print failure and never retries',
    () async {
      final history = LastPrintedHistory(AppStateStore(channel: channel));
      final document = LabelDocument();
      final job = LastPrintedJob.capture(document, history);
      failWrite = true;
      expect(await job.confirmed(), contains('не сохранён'));
      failWrite = false;
      expect(await job.confirmed(), isNull);
      expect(writes, 0);
      document.dispose();
    },
  );

  test(
    'corrupt saved state is surfaced rather than silently cleared',
    () async {
      files['lastPrinted'] = jsonEncode({'version': 500, 'document': {}});
      final history = LastPrintedHistory(AppStateStore(channel: channel));
      await expectLater(history.restore(), throwsFormatException);
      expect(files, isNotEmpty);
    },
  );
}
