import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/core/replay.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/ui/breakpoint/request_form.dart';
import 'package:proxie/src/ui/inspector_shell.dart';
import 'package:proxie/src/worker/worker.dart';

/// Sends [edited], the request of [original] as edited, and records it as
/// a new call (see [replayCall]), until [cancel] completes.
typedef ResendSender =
    Future<ReplayResult> Function(
      ProxieCall original,
      ProxieRequest edited,
      Future<void> cancel,
    );

/// The scope (see `OpenJson.scope`) the resend sheet of call [callId]
/// opens its body in, so its edits stay in it.
String resendScope(String callId) => 'resend:$callId';

/// Opens the [ResendSheet] of [call] on the inspector's navigator (see
/// [ProxieInspector.navigatorOf]). Completes when it closes.
Future<void> openResendSheet(
  BuildContext context, {
  required ProxieCall call,
  required ProxieWorker worker,
  required ResendSender send,
  int rawEditableLimit = defaultRawEditableLimit,
  ValueChanged<String>? onOpenCall,
}) => ProxieInspector.navigatorOf(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ResendSheet(
      call: call,
      worker: worker,
      send: send,
      rawEditableLimit: rawEditableLimit,
      onOpenCall: onOpenCall,
    ),
  ),
);

/// Edits the stored request of [call] (method, URL, query parameters,
/// headers, body) and sends it again with [send].
///
/// The stored request is the masked copy: masked values are pointed out,
/// and sent as they are unless retyped. A truncated body cannot be sent
/// until it is replaced. While it is sent, Cancel gives up on it. After a
/// send it says how the request went out and offers to open the new call.
class ResendSheet extends StatefulWidget {
  /// Creates the sheet of [call].
  const ResendSheet({
    required this.call,
    required this.worker,
    required this.send,
    super.key,
    this.rawEditableLimit = defaultRawEditableLimit,
    this.onOpenCall,
  });

  /// The call whose request is sent again, as stored.
  final ProxieCall call;

  /// Holds the body's JSON document and splits text.
  final ProxieWorker worker;

  /// Sends the edited request.
  final ResendSender send;

  /// Bodies of at least this many bytes open read-only until "Edit
  /// anyway".
  final int rawEditableLimit;

  /// Opens the detail of the new call; "Open call" is hidden when null.
  final ValueChanged<String>? onOpenCall;

  @override
  State<ResendSheet> createState() => _ResendSheetState();
}

class _ResendSheetState extends State<ResendSheet> {
  late final RequestDraft _draft = RequestDraft(
    widget.worker,
    scope: resendScope(widget.call.id),
  )..load(widget.call.request, callId: widget.call.id, live: false);
  bool _busy = false;
  String? _error;
  ReplayResult? _result;
  // The send under way; a send that is no longer this one is ignored.
  Completer<void>? _cancel;

  @override
  void initState() {
    super.initState();
    _draft.edited.addListener(_onEdited);
  }

  // What the error said is about the request before this edit.
  void _onEdited() {
    if (_error != null) setState(() => _error = null);
  }

  @override
  void dispose() {
    _draft.edited.removeListener(_onEdited);
    // Closes the body's JSON document of this scope too.
    _draft.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy || _draft.truncated) return;
    final problem = _draft.validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final cancel = Completer<void>();
    _cancel = cancel;
    bool current() => mounted && identical(_cancel, cancel);
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final edited = await _draft.build();
      if (!current()) return;
      final result = await widget.send(widget.call, edited, cancel.future);
      if (!current()) return;
      setState(() => _result = result);
    } on Object catch (e, st) {
      if (!current()) return;
      // A failed send is shown here; the host app must never crash.
      developer.log(
        'Proxie could not resend the request',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
      setState(() => _error = e is StateError ? e.message : 'Send failed: $e');
    } finally {
      if (current()) {
        _cancel = null;
        setState(() => _busy = false);
      }
    }
  }

  void _cancelSend() {
    final cancel = _cancel;
    if (cancel == null) return;
    _cancel = null;
    cancel.complete();
    setState(() {
      _busy = false;
      _error = 'Send cancelled';
    });
  }

  void _openCall(String callId) {
    final open = widget.onOpenCall;
    if (open == null) return;
    Navigator.of(context).pop();
    open(callId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = _result;
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('Edit & resend')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: RequestForm(
              draft: _draft,
              worker: widget.worker,
              rawEditableLimit: widget.rawEditableLimit,
            ),
          ),
          if (error != null)
            ColoredBox(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  error,
                  key: const ValueKey('resend-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          if (result != null && error == null)
            ColoredBox(
              color: scheme.surfaceContainer,
              child: Padding(
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${result.sentVia} · ${result.response.statusCode}',
                        key: const ValueKey('resend-result'),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    if (widget.onOpenCall != null)
                      TextButton(
                        onPressed: () => _openCall(result.callId),
                        child: const Text('Open call'),
                      ),
                  ],
                ),
              ),
            ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_busy) ...[
                    OutlinedButton(
                      onPressed: _cancelSend,
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  ListenableBuilder(
                    listenable: _draft,
                    builder: (context, _) => FilledButton.icon(
                      // A truncated body is never sent in part.
                      onPressed: _busy || _draft.truncated
                          ? null
                          : () => unawaited(_send()),
                      icon: const Icon(Icons.send),
                      label: const Text('Send'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
