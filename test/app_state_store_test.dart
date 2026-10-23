import 'package:d110_studio/app_state_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/app-state');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('slots persist independently across store instances', () async {
    final disk = <String, String>{};
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      final slot = args['slot'] as String;
      if (call.method == 'readState') return disk[slot];
      disk[slot] = args['json'] as String;
      return null;
    });
    final first = AppStateStore(channel: channel);
    expect(await first.read(AppStateSlot.lastPrinted), isNull);
    await first.write(AppStateSlot.lastPrinted, '{"printed":true}');
    await first.write(AppStateSlot.workspace, '{"draft":true}');
    await first.write(AppStateSlot.mediaProfile, '{"measured":false}');
    final reopened = AppStateStore(channel: channel);
    expect(await reopened.read(AppStateSlot.lastPrinted), '{"printed":true}');
    expect(await reopened.read(AppStateSlot.workspace), '{"draft":true}');
    expect(
      await reopened.read(AppStateSlot.mediaProfile),
      '{"measured":false}',
    );
  });

  test(
    'malformed read is an error and does not write an empty replacement',
    () async {
      var writes = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readState') return '{broken';
        writes++;
        return null;
      });
      await expectLater(
        AppStateStore(channel: channel).read(AppStateSlot.workspace),
        throwsFormatException,
      );
      expect(writes, 0);
    },
  );

  test('native read and write failures reach their caller', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'file_error');
    });
    final store = AppStateStore(channel: channel);
    await expectLater(
      store.read(AppStateSlot.workspace),
      throwsA(isA<PlatformException>()),
    );
    await expectLater(
      store.write(AppStateSlot.workspace, '{}'),
      throwsA(isA<PlatformException>()),
    );
  });
}
