import 'dart:io';

/// Releases only the temporary artifact returned by our camera shutter.
Future<void> release(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}
