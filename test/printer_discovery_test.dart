import 'package:d110_studio/printer.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/printer-discovery');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PrinterClient printer;
  late List<Map<String, Object?>> devices;
  String? remembered;

  Map<String, Object?> device(
    String name,
    int suffix, {
    bool? classic = true,
    bool? spp,
  }) => {
    'name': name,
    'address': 'AA:BB:CC:DD:EE:${suffix.toString().padLeft(2, '0')}',
    'classic': classic,
    'spp': spp,
  };

  setUp(() {
    remembered = null;
    devices = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'devices' => devices,
        'lastPrinterAddress' => remembered,
        'disconnect' => null,
        _ => throw PlatformException(code: 'unexpected', message: call.method),
      };
    });
    printer = PrinterClient(channel: channel);
  });

  tearDown(() {
    printer.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'discovery hides BLE twins, incompatible services and unrelated devices',
    () async {
      devices = [
        device('ORICO D110', 1, spp: true),
        device('D110_BLE', 2, classic: false),
        device('D110_GATT', 3, spp: false),
        device('Keyboard', 4),
        device('D110-1234', 5, classic: null),
        device('Wireless serial adapter', 6, spp: true),
        device('D110 BLE-1234', 7, spp: true),
      ];

      final candidates = await printer.devices();

      expect(candidates.map((d) => d.address), [
        'AA:BB:CC:DD:EE:01',
        'AA:BB:CC:DD:EE:05',
      ]);
    },
  );

  test(
    'a previously verified renamed printer survives missing service metadata',
    () async {
      remembered = 'AA:BB:CC:DD:EE:01';
      devices = [
        device('My roll printer', 1),
        device('Other serial device', 2, spp: true),
        device('Renamed BLE device', 3, classic: false),
      ];
      await printer.lastPrinterAddress();

      final candidates = await printer.devices();

      expect(candidates.map((d) => d.address), ['AA:BB:CC:DD:EE:01']);
    },
  );

  test(
    'malformed capability metadata is a bridge failure, not an empty scan',
    () async {
      devices = [
        {...device('D110', 1), 'classic': 'yes'},
      ];

      await expectLater(
        printer.devices(),
        throwsA(
          isA<PrinterException>().having(
            (failure) => failure.code,
            'code',
            'bridge_error',
          ),
        ),
      );
    },
  );
}
