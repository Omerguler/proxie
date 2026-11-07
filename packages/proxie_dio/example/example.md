# Example

```dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie_dio/proxie_dio.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://jsonplaceholder.typicode.com'));

void main() {
  // Records every call made with `dio`.
  Proxie.init(adapters: [ProxieDio.install(dio)]);
  runApp(const MaterialApp(builder: Proxie.wrap, home: Posts()));
}

class Posts extends StatelessWidget {
  const Posts({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ElevatedButton(
        onPressed: () => dio.get<dynamic>('/posts/1'),
        child: const Text('Fetch a post'),
      ),
    ),
  );
}
```
