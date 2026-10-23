import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

Future<String?> read(String slot, MethodChannel? channel) async {
  if (channel != null) {
    return channel.invokeMethod<String>('readState', {'slot': slot});
  }
  return web.window.localStorage.getItem('d110-studio.$slot');
}

Future<void> write(String slot, String json, MethodChannel? channel) async {
  if (channel != null) {
    await channel.invokeMethod<void>('writeState', {
      'slot': slot,
      'json': json,
    });
    return;
  }
  // setItem is atomic; quota/security errors must reach the editor.
  web.window.localStorage.setItem('d110-studio.$slot', json);
}
