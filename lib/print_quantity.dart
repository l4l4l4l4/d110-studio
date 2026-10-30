import 'package:flutter/material.dart';

class PrintQuantityDialog extends StatefulWidget {
  const PrintQuantityDialog({required this.tilesPerDesign, super.key});

  final int tilesPerDesign;

  @override
  State<PrintQuantityDialog> createState() => _PrintQuantityDialogState();
}

class _PrintQuantityDialogState extends State<PrintQuantityDialog> {
  final controller = TextEditingController(text: '1');

  int? get copies {
    final count = int.tryParse(controller.text.trim());
    return count != null && count >= 1 && count <= 99 ? count : null;
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = copies;
    void submit() {
      if (count != null) Navigator.pop(context, count);
    }

    return AlertDialog(
      title: const Text('Сколько копий?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('print-copies'),
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Копии дизайна',
              helperText: 'От 1 до 99',
              errorText: count == null
                  ? 'Введите целое число от 1 до 99'
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => submit(),
          ),
          const SizedBox(height: 12),
          Text(
            count == null
                ? 'Укажите количество копий.'
                : '${count * widget.tilesPerDesign} наклеек · '
                      '${widget.tilesPerDesign} на копию',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: count == null ? null : submit,
          child: const Text('Печатать'),
        ),
      ],
    );
  }
}
