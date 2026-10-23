import 'dart:convert';

import 'package:flutter/services.dart';
import 'app_state_storage_native.dart'
    if (dart.library.js_interop) 'app_state_storage_web.dart'
    as storage;

enum AppStateSlot { lastPrinted, workspace, mediaProfile }

/// Private durable JSON slots, separate from templates and printer selection.
/// Missing files return null; malformed data and storage failures are errors.
class AppStateStore {
  AppStateStore({MethodChannel? channel}) : _channel = channel;

  static const maxBytes = 64 * 1024 * 1024;
  final MethodChannel? _channel;

  Future<String?> read(AppStateSlot slot) async {
    final text = await storage.read(slot.name, _channel);
    if (text != null) _validate(text);
    return text;
  }

  Future<void> write(AppStateSlot slot, String json) async {
    _validate(json);
    await storage.write(slot.name, json, _channel);
  }

  void _validate(String text) {
    if (text.length > maxBytes || utf8.encode(text).length > maxBytes) {
      throw const FormatException('Состояние превышает лимит 64 МиБ');
    }
    jsonDecode(text);
  }
}
