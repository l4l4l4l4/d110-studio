import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;
import 'printer.dart';

Future<Uint8List?> pickStudioImage(PrinterClient printer) async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = 'image/*'
    ..multiple = false;
  input.style.display = 'none';
  final selected = Completer<web.File?>();
  Timer? focusTimer;
  var reading = false;
  void finish(web.File? file) {
    if (!selected.isCompleted) selected.complete(file);
  }

  final change = ((web.Event event) {
    reading = true;
    finish(input.files?.item(0));
  }).toJS;
  final cancel = ((web.Event event) => finish(null)).toJS;
  // Older browsers may return focus without emitting the input's cancel event.
  // Defer inspection so their change event gets to deliver the selected file.
  final focus = ((web.Event event) {
    focusTimer?.cancel();
    focusTimer = Timer(const Duration(milliseconds: 350), () {
      if (!reading) finish(input.files?.item(0));
    });
  }).toJS;
  input.addEventListener('change', change);
  input.addEventListener('cancel', cancel);
  web.window.addEventListener('focus', focus);
  try {
    web.document.body!.appendChild(input);
    input.click();
    final file = await selected.future;
    if (file == null) return null;
    if (file.size > 16 * 1024 * 1024) {
      throw const FormatException('Изображение должно быть не больше 16 МиБ');
    }
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } finally {
    focusTimer?.cancel();
    input.removeEventListener('change', change);
    input.removeEventListener('cancel', cancel);
    web.window.removeEventListener('focus', focus);
    input.remove();
  }
}
