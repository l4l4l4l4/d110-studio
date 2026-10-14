import 'dart:typed_data';
import 'printer.dart';

Future<Uint8List?> pickStudioImage(PrinterClient printer) =>
    printer.pickImage();
