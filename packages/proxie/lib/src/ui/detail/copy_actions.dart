import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:proxie/src/core/curl.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';

/// Targets of the detail screen's rule and resend actions.
///
/// Each callback is null until the feature providing it is wired in; a null
/// callback hides its button.
class ProxieDetailActions {
  /// Creates the action targets; omitted ones are hidden.
  const ProxieDetailActions({
    this.onMapLocal,
    this.onBreakpoint,
    this.onEditResend,
  });

  /// Creates a Map Local rule from the call's response. Shown only once the
  /// call has a response.
  final void Function(ProxieCall call)? onMapLocal;

  /// Creates a breakpoint on the call's URL.
  final void Function(ProxieCall call)? onBreakpoint;

  /// Opens the call's request for editing and sending again.
  final void Function(ProxieCall call)? onEditResend;
}

/// The request and response headers of [call] as text, one `name: value`
/// line per value, each side under its own heading.
String headersText(ProxieCall call) {
  String lines(Map<String, List<String>> headers) => [
    for (final e in headers.entries)
      for (final v in e.value) '${e.key}: $v',
  ].join('\n');
  final response = call.response;
  return [
    'Request headers',
    lines(call.request.headers),
    if (response != null) ...['', 'Response headers', lines(response.headers)],
  ].join('\n');
}

/// Writes [text] to the clipboard and confirms with "[what] copied" in the
/// nearest [ScaffoldMessenger]. A clipboard failure is logged and reported
/// in the same place, never thrown.
Future<void> copyToClipboard(
  BuildContext context,
  String text,
  String what,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  String message;
  try {
    await Clipboard.setData(ClipboardData(text: text));
    message = '$what copied';
  } on Object catch (e, st) {
    developer.log(
      'Proxie could not write to the clipboard',
      name: 'proxie',
      error: e,
      stackTrace: st,
    );
    message = "Couldn't copy $what";
  }
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
}

/// The copy menu of the detail screen: cURL, URL, request body, response
/// body and headers. Body items are disabled for bodies that are empty or
/// not text.
class CopyMenu extends StatelessWidget {
  /// Creates the copy menu for [call].
  const CopyMenu({required this.call, super.key});

  /// The call whose parts are copied.
  final ProxieCall call;

  @override
  Widget build(BuildContext context) {
    final response = call.response;
    // Texts are produced on selection only: cURL and body text decode up to
    // the whole body.
    final items = <(String, String, String? Function()?)>[
      ('Copy cURL', 'cURL', () => toCurl(call.request)),
      ('Copy URL', 'URL', call.request.url.toString),
      ('Copy request body', 'Request body', _bodyText(call.request.body)),
      (
        'Copy response body',
        'Response body',
        response == null ? null : _bodyText(response.body),
      ),
      ('Copy headers', 'Headers', () => headersText(call)),
    ];
    return PopupMenuButton<int>(
      tooltip: 'Copy',
      icon: const Icon(Icons.copy_all_outlined),
      onSelected: (i) {
        final (_, what, produce) = items[i];
        final text = produce?.call();
        if (text == null) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text("$what isn't text")));
          return;
        }
        unawaited(copyToClipboard(context, text, what));
      },
      itemBuilder: (context) => [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            enabled: items[i].$3 != null,
            child: Text(items[i].$1),
          ),
      ],
    );
  }

  static String? Function()? _bodyText(ProxieBody body) =>
      body.bytes.isEmpty ||
          (body.kind != BodyKind.text && body.kind != BodyKind.json)
      ? null
      : () => body.text;
}
