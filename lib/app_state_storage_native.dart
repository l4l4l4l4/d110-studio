import 'package:flutter/services.dart';

const _device = MethodChannel('d110_studio/device');

Future<String?> read(String slot, MethodChannel? channel) =>
    (channel ?? _device).invokeMethod<String>('readState', {'slot': slot});

Future<void> write(String slot, String json, MethodChannel? channel) =>
    (channel ?? _device).invokeMethod<void>('writeState', {
      'slot': slot,
      'json': json,
    });
