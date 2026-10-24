import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PrinterDevice {
  const PrinterDevice({
    required this.name,
    required this.address,
    this.supportsSpp,
  });

  final String name;
  final String address;
  final bool? supportsSpp;
}

class PrinterInfo {
  const PrinterInfo({
    required this.model,
    required this.firmware,
    required this.serial,
  });

  final String model;
  final String firmware;
  final String serial;
}

class PrinterException implements Exception {
  const PrinterException(this.message, {this.code = 'printer_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

/// The AiYin status byte, not the different two-byte FF/error response.
class PrinterStatus {
  const PrinterStatus(this.raw);

  final int raw;
  bool get printing => raw & 0x01 != 0;
  bool get coverOpen => raw & 0x02 != 0;
  bool get outOfPaper => raw & 0x04 != 0;
  bool get lowBattery => raw & 0x08 != 0;
  bool get overheated => raw & 0x50 != 0;
  bool get charging => raw & 0x20 != 0;
  bool get unknown => raw & 0x80 != 0;
  bool get ready =>
      !printing &&
      !coverOpen &&
      !outOfPaper &&
      !lowBattery &&
      !overheated &&
      !unknown;

  String get description {
    final flags = <String>[
      if (printing) 'Printer is already printing',
      if (coverOpen) 'Cover is open',
      if (outOfPaper) 'Out of paper',
      if (lowBattery) 'Battery is low; charge before printing',
      if (overheated) 'Printhead is overheated',
      if (charging) 'Charging',
      if (unknown) 'Unknown printer status (0x${raw.toRadixString(16)})',
    ];
    return flags.isEmpty ? 'Ready' : flags.join('; ');
  }
}

class BluetoothAdapterState {
  const BluetoothAdapterState({
    required this.available,
    required this.enabled,
    required this.permitted,
  });

  final bool available;
  // Null means power is undisclosed before permission, or inspection failed even
  // though permission is granted. It does not prove the adapter is switched off.
  final bool? enabled;
  final bool permitted;

  factory BluetoothAdapterState.fromMessage(Object? value) {
    if (value is! Map ||
        value['available'] is! bool ||
        value['permitted'] is! bool ||
        (value['enabled'] != null && value['enabled'] is! bool)) {
      throw const PrinterException(
        'Invalid Bluetooth adapter state',
        code: 'bridge_error',
      );
    }
    return BluetoothAdapterState(
      available: value['available'] as bool,
      enabled: value['enabled'] as bool?,
      permitted: value['permitted'] as bool,
    );
  }
}

enum BluetoothEnableResult { enabled, declined, settingsOpened }

/// Classic Bluetooth transport for the hardware-verified AiYin D110 only.
///
/// A failed/ambiguous exchange closes the connection. A print is never retried:
/// the label may already have been printed when its acknowledgement is lost.
class PrinterClient extends ChangeNotifier {
  PrinterClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('d110_studio/device') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'disconnected') {
        _markDisconnected();
      }
      if (call.method == 'adapterChanged') {
        _adapterGeneration++;
        _observeAdapter(BluetoothAdapterState.fromMessage(call.arguments));
        if (!_disposed) notifyListeners();
      }
    });
  }

  final MethodChannel _channel;
  static final _d110Name = RegExp(
    r'(^|[^a-z0-9])d110($|[^a-z0-9])',
    caseSensitive: false,
  );
  static final _bleName = RegExp(r'(^|[^a-z0-9])ble', caseSensitive: false);
  String? _rememberedAddress;
  bool _connected = false;
  bool _busy = false;
  bool _disposed = false;
  int _disconnectGeneration = 0;
  int _adapterGeneration = 0;
  int _adapterLossGeneration = 0;
  BluetoothAdapterState? _observedAdapter;

  bool get connected => _connected;
  bool get busy => _busy;
  int get adapterGeneration => _adapterGeneration;
  BluetoothAdapterState? get observedAdapter => _observedAdapter;

  void _observeAdapter(BluetoothAdapterState state) {
    _observedAdapter = state;
    if (!state.available || state.enabled == false) {
      _connected = false;
      _disconnectGeneration++;
      _adapterLossGeneration++;
    }
  }

  void _markDisconnected() {
    _connected = false;
    _disconnectGeneration++;
    if (!_disposed) notifyListeners();
  }

  void _requireActive() {
    if (_disposed) {
      throw const PrinterException(
        'The printer client is closed',
        code: 'disposed',
      );
    }
  }

  Future<T> _singleFlight<T>(Future<T> Function() action) async {
    _requireActive();
    if (_busy) {
      throw const PrinterException(
        'A printer operation is already in progress',
        code: 'busy',
      );
    }
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
      if (_disposed) await _closeAfterFailure();
      if (!_disposed) notifyListeners();
    }
  }

  void _requireConnection() {
    if (!_connected) {
      throw const PrinterException(
        'Connect a D110 first',
        code: 'disconnected',
      );
    }
  }

  Future<void> _closeAfterFailure() async {
    _markDisconnected();
    try {
      await _channel.invokeMethod<void>('disconnect');
    } catch (_) {
      // Preserve the original failure, not a secondary cleanup failure.
    }
  }

  Future<List<PrinterDevice>> devices() => _singleFlight(() async {
    final result = await _channel.invokeListMethod<Object?>('devices');
    if (result == null) {
      throw const PrinterException(
        'The device bridge returned no device list',
        code: 'bridge_error',
      );
    }
    final candidates = <PrinterDevice>[];
    for (final value in result) {
      if (value is! Map ||
          value['name'] is! String ||
          value['address'] is! String ||
          !value.containsKey('classic') ||
          !value.containsKey('spp') ||
          (value['classic'] != null && value['classic'] is! bool) ||
          (value['spp'] != null && value['spp'] is! bool)) {
        throw const PrinterException(
          'The device bridge returned invalid device capabilities',
          code: 'bridge_error',
        );
      }
      final name = value['name'] as String;
      final address = (value['address'] as String).toUpperCase();
      final known = address == _rememberedAddress;
      // A prior D110 handshake outweighs stale cached service/name metadata.
      // It cannot turn a BLE-only endpoint into a classic RFCOMM transport.
      if (value['classic'] == false ||
          (!known &&
              (value['spp'] == false ||
                  _bleName.hasMatch(name) ||
                  !_d110Name.hasMatch(name)))) {
        continue;
      }
      candidates.add(
        PrinterDevice(
          name: name,
          address: address,
          supportsSpp: value['spp'] as bool?,
        ),
      );
    }
    return candidates;
  });

  /// Local storage and passive adapter inspection never request OS permissions.
  Future<String?> lastPrinterAddress() async {
    _requireActive();
    final address = await _channel.invokeMethod<String>('lastPrinterAddress');
    _rememberedAddress = address?.trim().toUpperCase();
    return _rememberedAddress;
  }

  Future<BluetoothAdapterState> adapterState() => _singleFlight(() async {
    final generation = _adapterGeneration;
    final value = await _channel.invokeMapMethod<String, Object?>(
      'adapterState',
    );
    final state = BluetoothAdapterState.fromMessage(value);
    // A power broadcast received during the query is newer than its reply.
    if (generation == _adapterGeneration) _observeAdapter(state);
    return _observedAdapter ?? state;
  });

  Future<BluetoothEnableResult> requestEnableBluetooth() =>
      _singleFlight(() async {
        final result = await _channel.invokeMethod<String>(
          'requestEnableBluetooth',
        );
        return switch (result) {
          'enabled' => BluetoothEnableResult.enabled,
          'declined' => BluetoothEnableResult.declined,
          'settings_opened' => BluetoothEnableResult.settingsOpened,
          _ => throw const PrinterException(
            'Invalid Bluetooth enable result',
            code: 'bridge_error',
          ),
        };
      });

  Future<void> connect(
    String address, {
    bool requestPermission = true,
  }) => _singleFlight(() async {
    final normalized = address.trim().toUpperCase();
    if (!RegExp(r'^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(normalized)) {
      throw const PrinterException(
        'Invalid Bluetooth address',
        code: 'invalid_address',
      );
    }
    _connected = false;
    try {
      final adapterLossGeneration = _adapterLossGeneration;
      // Native connect also closes an old socket. Finish that intentional
      // disconnect before observing failures in the replacement handshake.
      await _channel.invokeMethod<void>('disconnect');
      _requireActive();
      final adapter = _observedAdapter;
      if (adapter != null && (!adapter.available || adapter.enabled == false)) {
        throw PrinterException(
          adapter.available
              ? 'Bluetooth is switched off'
              : 'The Bluetooth adapter is unavailable',
          code: adapter.available
              ? 'bluetooth_disabled'
              : 'bluetooth_unavailable',
        );
      }
      if (adapterLossGeneration != _adapterLossGeneration) {
        throw const PrinterException(
          'Bluetooth was interrupted while disconnecting the previous printer',
          code: 'disconnected',
        );
      }
      final generation = _disconnectGeneration;
      await _channel.invokeMethod<void>('connect', {
        'address': normalized,
        'requestPermission': requestPermission,
      });
      _requireActive();
      await _readModel();
      if (generation != _disconnectGeneration) {
        throw const PrinterException(
          'The printer disconnected during its model handshake',
          code: 'disconnected',
        );
      }
      _requireActive();
      // Only an accepted D110 model handshake may replace the last good address.
      await _channel.invokeMethod<void>('saveLastPrinterAddress', {
        'address': normalized,
      });
      _rememberedAddress = normalized;
      _requireActive();
      if (generation != _disconnectGeneration) {
        throw const PrinterException(
          'The printer disconnected while saving its address',
          code: 'disconnected',
        );
      }
      _connected = true;
      notifyListeners();
    } catch (_) {
      await _closeAfterFailure();
      rethrow;
    }
  });

  Future<void> disconnect() => _singleFlight(() async {
    _markDisconnected();
    await _channel.invokeMethod<void>('disconnect');
  });

  Future<PrinterInfo> info() => _singleFlight(() async {
    _requireConnection();
    try {
      return PrinterInfo(
        model: await _readModel(),
        firmware: await _readAscii(0xF1, 'firmware'),
        serial: await _readAscii(0xF2, 'serial number'),
      );
    } catch (_) {
      await _closeAfterFailure();
      rethrow;
    }
  });

  Future<Uint8List> _exchange(
    List<int> bytes, {
    int expectedLength = 0,
    int timeoutMs = 3000,
  }) async {
    final response = await _channel.invokeMethod<Uint8List>('exchange', {
      'bytes': Uint8List.fromList(bytes),
      'expectedLength': expectedLength,
      'timeoutMs': timeoutMs,
    });
    if (response == null ||
        response.isEmpty ||
        (expectedLength > 0 && response.length != expectedLength)) {
      throw const PrinterException(
        'Incomplete printer response; reconnect before continuing',
        code: 'protocol_error',
      );
    }
    return response;
  }

  Future<String> _readAscii(int query, String field) async {
    final bytes = await _exchange([0x10, 0xFF, 0x20, query]);
    if (bytes.any(
      (byte) => (byte < 0x20 && byte != 0x0A && byte != 0x0D) || byte > 0x7E,
    )) {
      throw PrinterException(
        'Invalid $field response from printer',
        code: 'protocol_error',
      );
    }
    final value = ascii.decode(bytes).trim();
    if (value.isEmpty) {
      throw PrinterException(
        'Empty $field response from printer',
        code: 'protocol_error',
      );
    }
    return value;
  }

  Future<String> _readModel() async {
    final model = await _readAscii(0xF0, 'model');
    if (model != 'D110') {
      throw PrinterException(
        'Unsupported printer model "$model". Only the verified AiYin D110 '
        'is supported; other NIIMBOT protocols are not compatible.',
        code: 'unsupported_model',
      );
    }
    return model;
  }

  Future<PrinterStatus> _status() async {
    final response = await _exchange([0x10, 0xFF, 0x40], expectedLength: 1);
    if (response[0] == 0xFF || response[0] & 0x80 != 0) {
      throw const PrinterException(
        'Invalid status response; reconnect before continuing',
        code: 'protocol_error',
      );
    }
    return PrinterStatus(response[0]);
  }

  Future<void> _expectOk(List<int> command) async {
    final response = await _exchange(command, expectedLength: 2);
    if (response[0] != 0x4F || response[1] != 0x4B) {
      throw const PrinterException(
        'Printer did not acknowledge the configuration command',
        code: 'protocol_error',
      );
    }
  }

  Future<void> _write(Uint8List bytes) =>
      _channel.invokeMethod<void>('write', {'bytes': bytes});

  Future<void> printRaster(
    Uint8List packed,
    int height, {
    int density = 2,
  }) => _singleFlight(() async {
    _requireConnection();
    if (density < 0 || density > 2) {
      throw const PrinterException(
        'Density must be 0, 1, or 2',
        code: 'invalid_density',
      );
    }
    if (height < 1 || height > 1200 || packed.length != height * 12) {
      throw const PrinterException(
        'Raster must contain exactly 12 bytes per row and 1–1200 rows',
        code: 'invalid_raster',
      );
    }
    // Snapshot before the first await so editor changes cannot alter a job.
    final raster = Uint8List(8 + packed.length);
    raster.setRange(0, 8, [
      0x1D,
      0x76,
      0x30,
      0x00,
      0x0C,
      0x00,
      height & 0xFF,
      height >> 8,
    ]);
    raster.setRange(8, raster.length, packed);

    late final PrinterStatus initial;
    try {
      initial = await _status();
    } catch (_) {
      await _closeAfterFailure();
      rethrow;
    }
    if (!initial.ready) {
      throw PrinterException(initial.description, code: 'not_ready');
    }

    try {
      await _expectOk([0x10, 0xFF, 0x10, 0x00, density]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await _expectOk([0x10, 0xFF, 0x84, 0x00]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _write(Uint8List(12));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _write(Uint8List.fromList([0x10, 0xFF, 0xFE, 0x01]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _write(raster);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _write(Uint8List.fromList([0x1D, 0x0C]));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final completion = await _exchange([
        0x10,
        0xFF,
        0xFE,
        0x45,
      ], timeoutMs: 30000);
      final acknowledged =
          (completion.length == 1 && completion[0] == 0xAA) ||
          (completion.length == 2 &&
              completion[0] == 0x4F &&
              completion[1] == 0x4B);
      if (!acknowledged) {
        throw const PrinterException(
          'Unrecognized print completion response. The label may have printed; '
          'check it before reconnecting and submitting another job.',
          code: 'protocol_error',
        );
      }
      final finalStatus = await _status();
      if (!finalStatus.ready) {
        throw PrinterException(
          'Print did not finish in a ready state: ${finalStatus.description}. '
          'Check the label before submitting another job.',
          code: 'not_ready',
        );
      }
    } catch (_) {
      await _closeAfterFailure();
      rethrow;
    }
  });

  Future<Uint8List?> pickImage() =>
      _channel.invokeMethod<Uint8List>('pickImage');

  Future<String> loadTemplates() async {
    final json = await _channel.invokeMethod<String>('loadTemplates');
    if (json == null) {
      throw const PrinterException(
        'The template bridge returned no data',
        code: 'storage_error',
      );
    }
    return json;
  }

  Future<void> saveTemplates(String json) =>
      _channel.invokeMethod<void>('saveTemplates', {'json': json});

  /// Detaches events immediately; an in-flight transaction closes when it unwinds.
  /// It is never replayed, including when a print acknowledgement was lost.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connected = false;
    _channel.setMethodCallHandler(null);
    if (!_busy) unawaited(_closeAfterFailure());
    super.dispose();
  }
}
