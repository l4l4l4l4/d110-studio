import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';
import 'label.dart';
import 'printer.dart';

class QrCalibrationSample {
  const QrCalibrationSample(this.id, this.payload, this.pitch, this.density);
  final String id, payload;
  final int pitch, density;
  int get modules => QrCode.fromData(
    data: payload,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  ).moduleCount;

  Future<LabelDocument> document() async {
    final side = (modules + 8) * pitch;
    if (side > LabelDocument.height) {
      throw StateError('Образец не помещается на печатающей головке');
    }
    final qr = LabelElement(
      kind: ElementKind.qr,
      text: payload,
      x: 4,
      y: ((LabelDocument.height - side) ~/ 2).toDouble(),
      width: side.toDouble(),
      height: side.toDouble(),
    );
    final document = LabelDocument(
      lengthMm: 30,
      elements: [
        qr,
        LabelElement(
          kind: ElementKind.text,
          text:
              '$id\n$pitch dots/module\nheat ${density + 1}\nM · $modules modules',
          fontSize: 11,
          x: side + 10.0,
          y: 6,
          width: 226.0 - side,
          height: 84,
        ),
      ],
    );
    try {
      await qr.prepare();
      return document;
    } catch (_) {
      document.dispose();
      rethrow;
    }
  }
}

List<QrCalibrationSample> qrCalibrationPlan() {
  final samples = <QrCalibrationSample>[];
  for (var heat = 0; heat < 3; heat++) {
    for (final payload in ['D110-CAL', 'https://s.lalala.ing/AbCdEf12']) {
      final modules = QrCode.fromData(
        data: payload,
        errorCorrectLevel: QrErrorCorrectLevel.M,
      ).moduleCount;
      for (
        var pitch = 1;
        pitch * (modules + 8) <= LabelDocument.height;
        pitch++
      ) {
        samples.add(
          QrCalibrationSample('Q${samples.length + 1}', payload, pitch, heat),
        );
      }
    }
  }
  return samples;
}

Future<void> showQrCalibration(BuildContext context, PrinterClient printer) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _Calibration(printer: printer),
    );

class _Calibration extends StatefulWidget {
  const _Calibration({required this.printer});
  final PrinterClient printer;
  @override
  State<_Calibration> createState() => _CalibrationState();
}

class _CalibrationState extends State<_Calibration> {
  final plan = qrCalibrationPlan();
  final observations = <Map<String, Object>>[];
  String media = '', printerInfo = '';
  int index = 0;
  bool printing = false, printed = false;
  String? error;

  Future<void> printSample() async {
    if (printing || printed || error != null || index == plan.length) return;
    setState(() {
      printing = true;
      error = null;
    });
    final sample = plan[index];
    LabelDocument? document;
    try {
      if (printerInfo.isEmpty) {
        final info = await widget.printer.info();
        printerInfo = '${info.model} / ${info.firmware}';
      }
      document = await sample.document();
      final raster = await renderLabel(document);
      await widget.printer.printRaster(
        raster.packed,
        raster.height,
        density: sample.density,
      );
      if (mounted) setState(() => printed = true);
    } catch (failure) {
      if (mounted) {
        setState(
          () => error =
              '$failure\nОбразец мог напечататься. Автоповтора нет; проверьте стикер.',
        );
      }
    } finally {
      document?.dispose();
      if (mounted) setState(() => printing = false);
    }
  }

  void record(String result) {
    if (printing ||
        index >= plan.length ||
        (result == 'print_uncertain' ? error == null : !printed)) {
      return;
    }
    final sample = plan[index];
    observations.add({
      'id': sample.id,
      'payload': sample.payload,
      'dots_per_module': sample.pitch,
      'modules': sample.modules,
      'heat': sample.density + 1,
      'scan': result,
    });
    setState(() {
      index++;
      printed = false;
      error = null;
    });
  }

  String report() => const JsonEncoder.withIndent('  ').convert({
    'printer': printerInfo,
    'media': media,
    'at': DateTime.now().toUtc().toIso8601String(),
    'protocol':
        'Three independent scans per printed sample; exact payload required.',
    'observations': observations,
    'note':
        'Only the recorded printer, media and heat are covered. Not a universal density guarantee.',
  });

  @override
  Widget build(BuildContext context) {
    final sample = index < plan.length ? plan[index] : null;
    return PopScope(
      canPop: !printing,
      child: AlertDialog(
        title: const Text('Калибровка QR · до 15 стикеров'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Без физического отпечатка плотность не измерена. Для каждого образца трижды сканируйте код с разного расстояния и проверяйте точный текст, а не только рамку распознавания.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  enabled: !printing && observations.isEmpty,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Лента: размер, марка, партия',
                  ),
                  onChanged: (value) => media = value,
                ),
                const SizedBox(height: 12),
                Text(
                  'Записано ${observations.length}/${plan.length}. $printerInfo',
                ),
                if (sample != null) ...[
                  Text(
                    '${sample.id}: ${sample.pitch} точек/модуль, нагрев ${sample.density + 1}, ${sample.modules} модулей',
                  ),
                  SelectableText(sample.payload),
                  if (printed)
                    const Text(
                      'Отпечаток подтверждён принтером. Отметьте результат трёх сканирований.',
                    ),
                ] else
                  const Text(
                    'Серия завершена. Скопируйте отчёт; выбирайте минимальный шаг, который стабильно читается на вашей ленте и нагреве.',
                  ),
                if (printing) const LinearProgressIndicator(),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: printing ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report()));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Отчёт скопирован')),
                );
              }
            },
            child: const Text('Копировать отчёт'),
          ),
          if (sample != null && !printed && error == null)
            FilledButton(
              onPressed: printing ? null : printSample,
              child: Text('Печатать ${sample.id}'),
            ),
          if (sample != null && error != null)
            TextButton(
              onPressed: printing ? null : () => record('print_uncertain'),
              child: const Text('Не повторять · дальше'),
            ),
          if (printed) ...[
            TextButton(
              onPressed: () => record('failed'),
              child: const Text('Не читается / не 3 из 3'),
            ),
            FilledButton(
              onPressed: () => record('3/3_exact'),
              child: const Text('Точно считан 3 из 3'),
            ),
          ],
        ],
      ),
    );
  }
}
