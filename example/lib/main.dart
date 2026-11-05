import 'package:dio/dio.dart';
import 'package:example/demo_requests.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:proxie/proxie.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Flutter web only builds its accessibility tree on request; the Playwright
  // tests find the buttons through it.
  if (kIsWeb) SemanticsBinding.instance.ensureSemantics();
  final dio = Dio();
  // Before runApp, so overlay back-button handling registers ahead of the
  // app's navigator.
  final ready = startProxie(dio);
  runApp(
    DemoApp(
      requests: demoRequests(
        client: Proxie.httpClient(),
        dio: dio,
        ready: ready,
      ),
    ),
  );
}

class DemoApp extends StatelessWidget {
  const DemoApp({required this.requests, super.key});

  final List<DemoRequest> requests;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Proxie example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    builder: Proxie.wrap,
    home: DemoHome(requests: requests),
  );
}

class DemoHome extends StatefulWidget {
  const DemoHome({required this.requests, super.key});

  final List<DemoRequest> requests;

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  final Map<String, String> _results = {};

  Future<void> _run(DemoRequest request) async {
    setState(() => _results[request.label] = 'Running...');
    String result;
    try {
      result = await request.run();
    } on Object catch (e) {
      // No network, for example: the demo shows it and carries on.
      result = 'Failed: $e';
    }
    if (!mounted) return;
    setState(() => _results[request.label] = result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Proxie example')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final request in widget.requests)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _DemoRow(
                request: request,
                result: _results[request.label],
                onPressed: () => _run(request),
              ),
            ),
        ],
      ),
    ),
  );
}

class _DemoRow extends StatelessWidget {
  const _DemoRow({
    required this.request,
    required this.result,
    required this.onPressed,
  });

  final DemoRequest request;
  final String? result;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final result = this.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ElevatedButton(
          onPressed: onPressed,
          // Inside the button, so the label merges into the button's own
          // semantics node, once, and the tap action stays.
          child: Semantics(
            label: request.label,
            excludeSemantics: true,
            child: Text(request.label),
          ),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              result,
              key: ValueKey('result-${request.label}'),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
