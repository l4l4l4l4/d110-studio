import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const shortenerOrigin = String.fromEnvironment(
  'D110_SHORTENER_ORIGIN',
  defaultValue: 'https://s.lalala.ing',
);

class ShortenerException implements Exception {
  const ShortenerException(this.message);
  final String message;
  @override
  String toString() => message;
}

bool hasLeadingZeroBits(List<int> digest, int bits) {
  final bytes = bits ~/ 8;
  for (var i = 0; i < bytes; i++) {
    if (digest[i] != 0) return false;
  }
  final rest = bits % 8;
  return rest == 0 || digest[bytes] >> (8 - rest) == 0;
}

/// A cancellable session owns its network requests and bounded foreground work.
/// Hash batches yield to the UI; cancelling closes sockets and stops hashing.
class ShorteningSession {
  ShorteningSession({Uri? origin})
    : origin = origin ?? Uri.parse(shortenerOrigin);
  final Uri origin;
  final http.Client _client = http.Client();
  final _aborted = Completer<void>();
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _abortRequests();
  }

  void _abortRequests() {
    if (_aborted.isCompleted) return;
    _aborted.complete();
    _client.close();
  }

  Never _timedOut() {
    _abortRequests();
    throw TimeoutException('Shortener request timed out');
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final request =
        http.AbortableRequest(
            'POST',
            origin.resolve(path),
            abortTrigger: _aborted.future,
          )
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/json'
          ..body = jsonEncode(body);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 20), onTimeout: _timedOut);
    final bytes = BytesBuilder(copy: false);
    final reader = StreamIterator(response.stream);
    try {
      await (() async {
        while (await reader.moveNext()) {
          final chunk = reader.current;
          if (bytes.length + chunk.length > 8192) {
            throw const ShortenerException(
              'Шортенер прислал слишком большой ответ.',
            );
          }
          bytes.add(chunk);
        }
      })().timeout(const Duration(seconds: 20), onTimeout: _timedOut);
    } finally {
      await reader.cancel();
    }
    if (response.statusCode == 429) {
      throw const ShortenerException('Лимит шортенера. Подождите полминуты.');
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw const ShortenerException(
        'Шортенер отклонил запрос. Проверьте ссылку или повторите позже.',
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map<String, dynamic>) {
      throw const ShortenerException('Несовместимый ответ шортенера.');
    }
    return decoded;
  }

  Future<String?> shorten(String url, {ValueChanged<int>? onWork}) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !{'https', 'http'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          utf8.encode(url).length > 4096) {
        throw const ShortenerException(
          'Введите полную HTTP или HTTPS ссылку без логина и пароля.',
        );
      }
      final challenge = await _post('/v1/challenge', {'url': url});
      final token = challenge['challenge'];
      final bits = challenge['bits'];
      if (challenge['version'] != 1 ||
          challenge['algorithm'] != 'sha256' ||
          token is! String ||
          token.length > 1024 ||
          bits is! int ||
          bits < 1 ||
          bits > 22) {
        throw const ShortenerException(
          'Несовместимая или слишком дорогая задача proof-of-work.',
        );
      }
      final prefix = utf8.encode('$token\n');
      final buffer = Uint8List(prefix.length + 16)..setAll(0, prefix);
      final timer = Stopwatch()..start();
      final slice = Stopwatch()..start();
      var nonce = 0;
      while (!_cancelled) {
        // Reuse the UTF-8 token and decimal nonce buffer rather than allocating
        // and copying the complete challenge for every attempted hash.
        var number = nonce;
        var cursor = buffer.length;
        do {
          buffer[--cursor] = 48 + number % 10;
          number ~/= 10;
        } while (number != 0);
        final digits = buffer.length - cursor;
        for (var i = 0; i < digits; i++) {
          buffer[prefix.length + i] = buffer[cursor + i];
        }
        final digest = sha256.convert(
          Uint8List.sublistView(buffer, 0, prefix.length + digits),
        );
        if (hasLeadingZeroBits(digest.bytes, bits)) break;
        nonce++;
        if (nonce % 256 == 0 && slice.elapsedMilliseconds >= 8) {
          onWork?.call(nonce);
          if (timer.elapsed > const Duration(minutes: 3)) {
            throw const ShortenerException(
              'Расчёт занял слишком долго. Попробуйте ещё раз.',
            );
          }
          await Future<void>.delayed(Duration.zero);
          slice.reset();
        }
      }
      if (_cancelled) return null;
      final result = await _post('/v1/links', {
        'url': url,
        'challenge': token,
        'nonce': '$nonce',
      });
      if (_cancelled) return null;
      final shortened = result['short_url'];
      final parsed = shortened is String ? Uri.tryParse(shortened) : null;
      if (parsed == null ||
          parsed.origin != origin.origin ||
          !RegExp(r'^/[A-Za-z0-9_-]{8}$').hasMatch(parsed.path) ||
          parsed.hasQuery ||
          parsed.hasFragment) {
        throw const ShortenerException(
          'Шортенер вернул некорректную короткую ссылку.',
        );
      }
      return shortened as String;
    } on ShortenerException {
      if (_cancelled) return null;
      rethrow;
    } catch (_) {
      if (_cancelled) return null;
      throw const ShortenerException(
        'Шортенер недоступен. Исходная ссылка сохранена; проверьте сеть и доступность сервиса.',
      );
    } finally {
      _abortRequests();
    }
  }
}

/// QR text remains arbitrary; shortening is explicit and never automatic.
Future<String?> showQrTextDialog(BuildContext context, String initial) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _QrTextDialog(initial: initial),
    );

class _QrTextDialog extends StatefulWidget {
  const _QrTextDialog({required this.initial});
  final String initial;
  @override
  State<_QrTextDialog> createState() => _QrTextDialogState();
}

class _QrTextDialogState extends State<_QrTextDialog> {
  late String value;
  bool shorten = false;
  ShorteningSession? session;
  String? error;
  int hashes = 0;

  @override
  void initState() {
    super.initState();
    value = widget.initial;
  }

  @override
  void dispose() {
    session?.cancel();
    super.dispose();
  }

  bool get _routeActive => mounted && ModalRoute.of(context)?.isCurrent == true;

  Future<void> save() async {
    if (session != null || !_routeActive) return;
    if (!shorten) {
      Navigator.pop(context, value);
      return;
    }
    final operation = ShorteningSession();
    setState(() {
      session = operation;
      error = null;
      hashes = 0;
    });
    try {
      final result = await operation.shorten(
        value,
        onWork: (count) {
          if (_routeActive) setState(() => hashes = count);
        },
      );
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          result != null) {
        Navigator.pop(context, result);
      }
    } catch (failure) {
      if (_routeActive) {
        setState(() {
          session = null;
          error = failure.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    onPopInvokedWithResult: (didPop, result) {
      if (didPop) session?.cancel();
    },
    child: AlertDialog(
      title: const Text('Содержимое QR'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                initialValue: widget.initial,
                autofocus: true,
                maxLines: 3,
                enabled: session == null,
                onChanged: (text) => value = text,
                decoration: const InputDecoration(
                  labelText: 'Текст или ссылка',
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Короткая ссылка · lalala.ing'),
                subtitle: const Text(
                  'Без аккаунта. Ссылка отправится на публичный сервер; устройство посчитает proof-of-work.',
                ),
                value: shorten,
                onChanged: session == null
                    ? (checked) => setState(() => shorten = checked!)
                    : null,
              ),
              if (session != null) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 8),
                Text(
                  hashes == 0
                      ? 'Получение задачи…'
                      : 'Proof-of-work: $hashes хешей. Можно отменить.',
                ),
              ],
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            session?.cancel();
            if (_routeActive) Navigator.pop(context);
          },
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: session == null ? save : null,
          child: Text(shorten ? 'Сократить и вставить' : 'Сохранить'),
        ),
      ],
    ),
  );
}
