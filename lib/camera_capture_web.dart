import 'package:web/web.dart' as web;

/// Releases only the Blob URL returned by our camera shutter, never imports.
Future<void> release(String path) async {
  web.URL.revokeObjectURL(path);
}
