import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:example/http_client_request_stub.dart'
    if (dart.library.io) 'package:example/http_client_request_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:proxie/proxie.dart';
import 'package:proxie_dio/proxie_dio.dart';

const _jsonApi = 'https://jsonplaceholder.typicode.com';
const _httpbin = 'https://httpbin.org';

/// Answered by the Big JSON Map Local rule; `.invalid` never resolves, so the
/// demo cannot depend on the network.
const bigJsonUrl = 'https://big-json.invalid/data.json';

/// Identifies the Big JSON rule across launches.
const bigJsonRuleId = 'example-big-json';

/// Size of the generated Big JSON body. Below Proxie's 5 MiB capture cap, so
/// the body is served whole.
const bigJsonBytes = 5000000;

/// Shown by the Big JSON button when Proxie is not running: only Proxie can
/// answer that URL.
const bigJsonProxieOff =
    'Proxie is not running, so nothing can answer this request. '
    'Non-debug builds need --dart-define=PROXIE=true: see example/README.md.';

/// One demo button: its stable [label] and the request behind it.
class DemoRequest {
  const DemoRequest(this.label, this.run);

  /// Button text and semantics label; the e2e tests find buttons by it.
  final String label;

  /// Sends the request and returns the text shown under the button.
  final Future<String> Function() run;
}

/// The demo buttons, top to bottom. Every request waits for [ready] so that
/// an early tap is still recorded.
List<DemoRequest> demoRequests({
  required http.Client client,
  required Dio dio,
  required Future<void> ready,
}) {
  DemoRequest demo(String label, Future<String> Function() run) =>
      DemoRequest(label, () async {
        await ready;
        return await run();
      });

  Future<String> get(String url) async {
    final response = await client.get(Uri.parse(url));
    return _summary(response.statusCode, response.bodyBytes.length);
  }

  return [
    demo('GET JSON', () => get('$_jsonApi/todos/1')),
    demo('POST JSON', () async {
      final response = await client.post(
        Uri.parse('$_jsonApi/posts'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'title': 'Proxie', 'body': 'demo', 'userId': 1}),
      );
      return _summary(response.statusCode, response.bodyBytes.length);
    }),
    demo('404', () => get('$_httpbin/status/404')),
    demo('500', () => get('$_httpbin/status/500')),
    demo('Big JSON (5 MB)', () async {
      final engine = Proxie.engine;
      if (engine == null) return bigJsonProxieOff;
      await ensureBigJsonRule(engine);
      return await get(bigJsonUrl);
    }),
    demo('Image', () => get('$_httpbin/image/png')),
    demo('Dio GET', () async {
      final response = await dio.get<List<int>>(
        '$_jsonApi/users/1',
        options: Options(responseType: ResponseType.bytes),
      );
      return _summary(response.statusCode, response.data?.length ?? 0);
    }),
    if (!kIsWeb)
      demo('HttpClient GET', () => httpClientGet(Uri.parse('$_httpbin/get'))),
  ];
}

String _summary(int? status, int length) => '$status ($length bytes)';

/// Starts Proxie with all three adapters. Never throws: Proxie reports its own
/// failures, and requests then go out unrecorded.
Future<void> startProxie(Dio dio) {
  final interceptor = ProxieDio.install(dio);
  return Proxie.init(adapters: [ProxieHttpOverridesAdapter(), interceptor]);
}

/// Adds the Big JSON Map Local rule to [engine] unless it already has it.
/// Called on each tap of the button, so an app that never taps it does not
/// hold the 5 MB, and a rule the user deleted returns only with the next tap.
///
/// The rule is live but not stored: the public API has no call that stores a
/// rule. It reaches the store when the inspector next saves any rule, and
/// then comes back through Proxie's own rule loading on the next launch, with
/// the user's edits. The id check keeps that from duplicating it.
Future<void> ensureBigJsonRule(ProxieEngine engine) async {
  bool exists() => engine.rules.rules.any((r) => r.id == bigJsonRuleId);
  if (exists()) return;
  // On the web `compute` runs on the UI thread: there are no isolates there.
  final body = await compute(_bigJsonBody, bigJsonBytes);
  // The inspector may have changed the rules while the body was generated.
  if (exists()) return;
  final rule = ProxieRule(
    id: bigJsonRuleId,
    name: 'Big JSON (5 MB)',
    kind: RuleKind.mapLocal,
    matcher: UrlMatcher(bigJsonUrl),
    method: 'GET',
    mapLocal: MapLocalAction(
      response: ProxieResponse(
        statusCode: 200,
        headers: const {
          'content-type': ['application/json'],
        },
        body: body,
      ),
    ),
  );
  engine.rules = RuleSet([rule, ...engine.rules.rules]);
}

ProxieBody _bigJsonBody(int targetBytes) =>
    ProxieBody.from(generateBigJson(targetBytes), 'application/json');

/// A JSON document of at most [targetBytes], and within one row of it.
Uint8List generateBigJson(int targetBytes) {
  const open = '{"generated":true,"items":[';
  const close = ']}';
  final out = StringBuffer(open);
  for (var i = 0; ; i++) {
    final flags = '"active":${i.isEven},"score":${i % 100}.5';
    final tags = '["demo","big","group-${i % 16}"]';
    final address = '{"city":"City ${i % 500}","zip":"${10000 + i % 90000}"}';
    final row =
        '{"id":$i,"name":"Item $i",$flags,"tags":$tags,"address":$address}';
    final separator = i == 0 ? 0 : 1;
    if (out.length + separator + row.length + close.length > targetBytes) {
      break;
    }
    if (i > 0) out.write(',');
    out.write(row);
  }
  out.write(close);
  return utf8.encode(out.toString());
}
