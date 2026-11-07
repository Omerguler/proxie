import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

import 'store_contract.dart';

void main() {
  runStoreContract(({now}) async => MemoryStore(now: now));

  group('MemoryStore byte budget', () {
    final t0 = DateTime.utc(2026);

    ProxieCall sized(
      String id,
      int minute, {
      int request = 0,
      int response = 0,
    }) => ProxieCall(
      id: id,
      sessionId: 1,
      adapter: 'a',
      request: ProxieRequest(
        method: 'POST',
        url: Uri.parse('https://x.test/$id'),
        headers: const {},
        body: ProxieBody.from(Uint8List(request), 'application/octet-stream'),
      ),
      response: ProxieResponse(
        statusCode: 200,
        headers: const {},
        body: ProxieBody.from(Uint8List(response), 'application/octet-stream'),
      ),
      startedAt: t0.add(Duration(minutes: minute)),
    );

    Future<List<String>> ids(MemoryStore store) async {
      final page = await store.query(const CallQuery(), offset: 0, limit: 100);
      return [for (final c in page) c.id];
    }

    test('is 100 MB by default', () {
      expect(MemoryStore().maxBodyBytes, 100 * 1024 * 1024);
    });

    test('evicts the oldest first, counting both bodies', () async {
      final store = MemoryStore(maxBodyBytes: 100);
      await store.upsert(sized('a', 1, request: 30));
      await store.upsert(sized('b', 2, response: 30));
      await store.upsert(sized('c', 3, request: 20, response: 20));
      expect(await ids(store), ['c', 'b', 'a']);
      await store.upsert(sized('d', 4, response: 1));
      expect(await ids(store), ['d', 'c', 'b']);
      await store.upsert(sized('e', 5, request: 59));
      expect(await ids(store), ['e', 'd', 'c']);
    });

    test('the newest stays even when it alone is over budget', () async {
      final store = MemoryStore(maxBodyBytes: 100);
      await store.upsert(sized('a', 1, request: 10));
      await store.upsert(sized('big', 2, response: 500));
      expect(await ids(store), ['big']);
      expect(await store.get('big'), isNotNull);
      await store.upsert(sized('next', 3, request: 1));
      expect(await ids(store), ['next']);
    });

    test('a late answer to an old call does not push out the newest', () async {
      final store = MemoryStore(maxBodyBytes: 100);
      await store.upsert(sized('old', 1));
      await store.upsert(sized('new', 2, request: 60));
      await store.upsert(sized('old', 1, response: 60));
      expect(await ids(store), ['new']);
    });

    test('updating a call counts its bodies once', () async {
      final store = MemoryStore(maxBodyBytes: 100);
      await store.upsert(sized('a', 1, request: 60));
      await store.upsert(sized('b', 2, request: 30));
      for (var i = 0; i < 5; i++) {
        await store.upsert(sized('b', 2, request: 30, response: 10));
      }
      expect(await ids(store), ['b', 'a']);
    });

    test('calls gone by trim or clear no longer count', () async {
      final store = MemoryStore(maxBodyBytes: 100, now: () => t0);
      await store.upsert(sized('a', 1, request: 60));
      await store.trim(maxCalls: 0, maxAge: const Duration(days: 1));
      await store.upsert(sized('b', 2, request: 60));
      expect(await ids(store), ['b']);
      await store.clear();
      await store.upsert(sized('c', 3, request: 60));
      await store.upsert(sized('d', 4, request: 40));
      expect(await ids(store), ['d', 'c']);
    });
  });

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
