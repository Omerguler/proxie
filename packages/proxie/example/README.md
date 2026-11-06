# Proxie example

A complete demo app that uses all three adapters (`package:http`, Dio and
`dart:io` `HttpClient`) is in the repository:
[example](https://github.com/Omerguler/proxie/tree/main/example).

The smallest setup looks like this:

```dart
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:proxie/proxie.dart';

final http.Client client = Proxie.httpClient();

void main() {
  Proxie.init();
  runApp(MaterialApp(builder: Proxie.wrap, home: const Home()));
}

class Home extends StatelessWidget {
  const Home({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        onPressed: () => client.get(
          Uri.parse('https://jsonplaceholder.typicode.com/todos/1'),
        ),
        child: const Text('Send a request'),
      ),
    ),
  );
}
```

Tap the button, then tap the Proxie bubble to see the call.
