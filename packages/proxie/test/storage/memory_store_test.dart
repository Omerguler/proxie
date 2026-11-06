import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

import 'store_contract.dart';

void main() {
  runStoreContract(({now}) async => MemoryStore(now: now));

  group('MemoryStore clock', () {
    test(
      'trim removes calls older than maxAge using the injected clock',
      () async {
        final now = DateTime.utc(2026, 1, 10);
        final store = MemoryStore(now: () => now);
        for (final (id, age) in [('old', 10), ('mid', 3), ('new', 0)]) {
          await store.upsert(
            ProxieCall(
              id: id,
              sessionId: 1,
              adapter: 'a',
              request: ProxieRequest(
                method: 'GET',
                url: Uri.parse('https://x.test/$id'),
                headers: const {},
                body: ProxieBody.empty(),
              ),
              startedAt: now.subtract(Duration(days: age)),
            ),
          );
        }
        await store.trim(maxCalls: 100, maxAge: const Duration(days: 5));
        final ids = (await store.query(
          const CallQuery(),
          offset: 0,
          limit: 10,
        )).map((s) => s.id);
        expect(ids, ['new', 'mid']);
      },
    );

    test('session startedAt comes from the clock', () async {
      final now = DateTime.utc(2026, 1, 10, 8);
      final store = MemoryStore(now: () => now);
      await store.startSession();
      expect((await store.sessions()).single.startedAt, now);
    });
  });
  group('MemoryStore corrupt rows', () {
    final validRule = ProxieRule(
      id: 'ok',
      name: 'ok',
      kind: RuleKind.breakpoint,
      matcher: UrlMatcher('*'),
    );

    test('rules() skips undecodable rows and keeps the valid ones', () async {
      final store = MemoryStore();
      await store.saveRules([validRule]);
      store
        ..debugInsertRawRule({
          ...validRule.toMap(),
          'id': 'bad-kind',
          'kind': 'futureKind',
        })
        ..debugInsertRawRule({...validRule.toMap(), 'name': 42})
        ..debugInsertRawRule({'garbage': true})
        ..debugInsertRawRule({...validRule.toMap(), 'id': 'ok2'});
      expect((await store.rules()).map((r) => r.id), ['ok', 'ok2']);
    });

    test('customPresets() skips undecodable rows', () async {
      final store = MemoryStore();
      await store.saveCustomPreset(
        'good',
        'Good',
        const MapLocalAction(failure: SimulatedFailure.timeout),
      );
      store
        ..debugInsertRawPreset('bad1', {
          'id': 'bad1',
          'label': 'x',
          'action': {'failure': 'nope'},
        })
        ..debugInsertRawPreset('bad2', {'id': 'bad2'});
      expect((await store.customPresets()).map((p) => p.id), ['good']);
    });
  });
}
