import 'dart:convert';

import 'package:flutter/services.dart';

class PrinterDevice {
  const PrinterDevice({required this.name, required this.address});

  final String name;
  final String address;
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

/// Classic Bluetooth transport for the hardware-verified AiYin D110 only.
///
/// A failed/ambiguous exchange closes the connection. A print is never retried:
/// the label may already have been printed when its acknowledgement is lost.
class PrinterClient {
  PrinterClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('d110_studio/device') {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'disconnected') {
        _connected = false;
        _disconnectGeneration++;
      }
    });
  }

  final MethodChannel _channel;
  bool _connected = false;
  bool _busy = false;
  int _disconnectGeneration = 0;

  bool get connected => _connected;

  Future<T> _singleFlight<T>(Future<T> Function() action) async {
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
    _connected = false;
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
    return result
        .map((value) {
          if (value is! Map ||
              value['name'] is! String ||
              value['address'] is! String) {
            throw const PrinterException(
              'The device bridge returned an invalid device',
              code: 'bridge_error',
            );
          }
          return PrinterDevice(
            name: value['name'] as String,
            address: value['address'] as String,
          );
        })
        .toList(growable: false);
  });

  Future<void> connect(String address) => _singleFlight(() async {
    final normalized = address.trim().toUpperCase();
    if (!RegExp(r'^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(normalized)) {
      throw const PrinterException(
        'Invalid Bluetooth address',
        code: 'invalid_address',
      );
    }
    _connected = false;
    try {
      await _channel.invokeMethod<void>('connect', {'address': normalized});
      final generation = _disconnectGeneration;
      await _readModel();
      if (generation != _disconnectGeneration) {
        throw const PrinterException(
          'The printer disconnected during its model handshake',
          code: 'disconnected',
        );
      }
      _connected = true;
    } catch (_) {
      await _closeAfterFailure();
      rethrow;
    }
  });

  Future<void> disconnect() => _singleFlight(() async {
    _connected = false;
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
}
