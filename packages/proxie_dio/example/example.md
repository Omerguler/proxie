# Example

```dart
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:proxie_dio/proxie_dio.dart';

final dio = Dio(BaseOptions(baseUrl: 'https://jsonplaceholder.typicode.com'));

void main() {
  // Records every call made with `dio` once attached to a Proxie engine.
  ProxieDio.install(dio);
  runApp(const MaterialApp(home: Posts()));
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
