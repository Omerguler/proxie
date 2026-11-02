import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/adapter.dart';

class _Sink implements CallSink {
  @override
  void upsert(_) {}
}

class _Adapter implements ProxieCaptureAdapter {
  @override
  String get name => 'test';
  @override
  bool get supportsReplay => false;
  @override
  void attach(ProxieEngine engine) {}
  @override
  void detach() {}
  @override
  Future<ProxieResponse> replay(ProxieRequest request) =>
      throw UnimplementedError();
}

void main() {
  test('adapter library exposes what an adapter needs', () async {
    final engine = ProxieEngine(config: const ProxieConfig(), sink: _Sink());
    addTearDown(engine.dispose);
    final ProxieCaptureAdapter adapter = _Adapter()..attach(engine);
    expect(adapter.name, 'test');

    final req = ProxieRequest(
      method: 'GET',
      url: Uri.parse('https://example.com'),
      headers: const {},
      body: ProxieBody.from(Uint8List(0), null),
    );
    final id = engine.newCallId();
    final d = await engine.onRequest(id, 'test', req);
    expect(d, isA<Proceed>());
    final res = ProxieResponse(
      statusCode: 200,
      headers: const {},
      body: ProxieBody.empty(),
    );
    expect(await engine.onResponse(id, res), same(res));

    expect(runMarkedCaptured(isProxieCaptured), isTrue);
    expect(isProxieCaptured(), isFalse);
    expect(kProxieCapturedZoneKey, isA<Symbol>());
    expect(ProxieBody.empty().kind, BodyKind.empty);
    expect(defaultBodyCap, engine.config.teeCap);
    const action = MapLocalAction(failure: SimulatedFailure.timeout);
    expect(const Mock(action).action.failure, SimulatedFailure.timeout);
    const err = ProxieError(type: 'aborted', message: 'm');
    expect(const AbortRequest(err).error, same(err));
    expect(const ProxieAbortedException(err).error, same(err));
  });
}
