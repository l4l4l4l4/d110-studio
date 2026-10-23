import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:d110_studio/shortener.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class _EndpointClient extends http.BaseClient {
  _EndpointClient(this.respond);
  final FutureOr<http.StreamedResponse> Function(
    http.BaseRequest request,
    List<int> body,
  )
  respond;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (closed) throw http.ClientException('Client closed', request.url);
    return respond(request, await request.finalize().toBytes());
  }

  @override
  void close() => closed = true;
}

http.StreamedResponse _json(Object value, [int status = 200]) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(value))), status);

Map<String, Object> _challenge({int bits = 8}) => {
  'version': 1,
  'algorithm': 'sha256',
  'challenge': 'fixture-v1',
  'bits': bits,
};

class _StalledBody {
  final listening = Completer<void>();
  bool cancelled = false;
  late final body = StreamController<List<int>>(
    onListen: listening.complete,
    onCancel: () => cancelled = true,
  );

  http.StreamedResponse response(http.BaseRequest request) {
    // BrowserClient.close() no longer owns a fetch after its headers arrive.
    // A conforming Abortable transport still aborts its active body reader.
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger.then((_) {
          if (!body.isClosed) {
            body.addError(http.RequestAbortedException(request.url));
            unawaited(body.close());
          }
        }),
      );
    }
    return http.StreamedResponse(body.stream, 200);
  }
}

void main() {
  final origin = Uri.parse('https://s.example.test');

  test(
    'cancelling after headers releases a stalled response immediately',
    () async {
      final stalled = _StalledBody();
      final client = _EndpointClient((request, _) => stalled.response(request));
      final session = http.runWithClient(
        () => ShorteningSession(origin: origin),
        () => client,
      );
      final operation = session.shorten('https://example.com/');
      try {
        await stalled.listening.future;
        session.cancel();
        expect(
          await operation.timeout(const Duration(milliseconds: 250)),
          isNull,
        );
        expect(stalled.cancelled, isTrue);
      } finally {
        session.cancel();
        await stalled.body.close();
        await operation;
      }
    },
  );

  testWidgets('request deadline releases an already received stalled body', (
    tester,
  ) async {
    final stalled = _StalledBody();
    final client = _EndpointClient((request, _) => stalled.response(request));
    final session = http.runWithClient(
      () => ShorteningSession(origin: origin),
      () => client,
    );
    Object? result;
    var finished = false;
    unawaited(
      session
          .shorten('https://example.com/')
          .then<void>(
            (value) {
              result = value;
              finished = true;
            },
            onError: (Object error) {
              result = error;
              finished = true;
            },
          ),
    );
    try {
      await tester.pump();
      expect(stalled.listening.isCompleted, isTrue);
      await tester.pump(const Duration(seconds: 21));
      expect(stalled.cancelled, isTrue);
      // Settle asynchronous cancellation outside the fake clock.
      await tester.runAsync(() async {});
      await tester.pump();
      expect(finished, isTrue);
      expect(result, isA<ShortenerException>());
    } finally {
      session.cancel();
      unawaited(stalled.body.close());
    }
  });

  test(
    'real SHA-256 work preserves literal URL encoding through creation',
    () async {
      const target = 'https://example.com/p?a=%2Fb&signature=%2B%3D#frag';
      String? createdTarget;
      final client = _EndpointClient((request, bytes) {
        final payload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (request.url.path == '/v1/challenge') {
          return _json(_challenge());
        }
        createdTarget = payload['url'] as String;
        final proof = sha256.convert(
          utf8.encode('${payload['challenge']}\n${payload['nonce']}'),
        );
        if (!hasLeadingZeroBits(proof.bytes, 8)) {
          return _json({'error': 'proof'}, 400);
        }
        return _json({'short_url': '$origin/AbCd123_'}, 201);
      });
      final session = http.runWithClient(
        () => ShorteningSession(origin: origin),
        () => client,
      );
      expect(await session.shorten(target), '$origin/AbCd123_');
      expect(createdTarget, target);
    },
  );

  test('excessive work is refused before creating a link', () async {
    var created = false;
    final client = _EndpointClient((request, _) {
      if (request.url.path == '/v1/links') created = true;
      return _json(_challenge(bits: 23));
    });
    final session = http.runWithClient(
      () => ShorteningSession(origin: origin),
      () => client,
    );
    await expectLater(
      session.shorten('https://example.com/'),
      throwsA(isA<ShortenerException>()),
    );
    expect(created, isFalse);
  });

  test('a response cannot substitute a different short-link origin', () async {
    final client = _EndpointClient(
      (request, _) => request.url.path == '/v1/challenge'
          ? _json(_challenge())
          : _json({'short_url': 'https://unrelated.example/AbCd123_'}, 201),
    );
    final session = http.runWithClient(
      () => ShorteningSession(origin: origin),
      () => client,
    );
    await expectLater(
      session.shorten('https://example.com/'),
      throwsA(isA<ShortenerException>()),
    );
  });

  testWidgets('Back during shortening cannot pop the underlying editor route', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    late Future<String?> dialog;
    final editor = MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () =>
              dialog = showQrTextDialog(context, 'https://example.com/'),
          child: const Text('Open QR'),
        ),
      ),
    );
    final linkReply = Completer<http.StreamedResponse>();
    var linkRequested = false;
    final client = _EndpointClient((request, _) {
      if (request.url.path == '/v1/challenge') return _json(_challenge());
      linkRequested = true;
      return linkReply.future;
    });
    addTearDown(() {
      if (!linkReply.isCompleted) {
        linkReply.complete(_json({'error': 'closed'}, 503));
      }
    });
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    unawaited(navigator.currentState!.push<void>(editor));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    final submit = tester
        .widget<FilledButton>(find.byType(FilledButton))
        .onPressed!;
    late Future<void> operation;
    await tester.runAsync(() async {
      operation = http.runWithClient(
        () => (submit as Future<void> Function())(),
        () => client,
      );
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
    expect(linkRequested, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pump();
    // Deliver a reply during the reverse animation, before State.dispose().
    linkReply.complete(
      _json({
        'short_url': '${Uri.parse(shortenerOrigin).origin}/AbCd123_',
      }, 201),
    );
    await tester.pump();
    await tester.runAsync(() => operation);
    await tester.pump();
    expect(editor.isCurrent, isTrue);
    expect(await dialog, isNull);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
