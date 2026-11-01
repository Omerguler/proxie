import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

import 'store_contract.dart';

void main() {
  runStoreContract(() async => MemoryStore());

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
}
