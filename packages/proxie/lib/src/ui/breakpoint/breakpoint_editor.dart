import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/core/breakpoint_controller.dart';
import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/ui/breakpoint/request_form.dart';
import 'package:proxie/src/ui/inspector_shell.dart';
import 'package:proxie/src/ui/rules/response_editor.dart';
import 'package:proxie/src/worker/worker.dart';

/// The scope (see `OpenJson.scope`) the editor opens the body of [call]
/// in: one per call and phase, so its edits stay in it.
String breakpointScope(PausedCall call) =>
    'breakpoint:${call.callId}:${call.phase.name}';

/// Edits the oldest call paused in [breakpoints]: its request (method,
/// URL, query parameters, headers, body) or its response (status, headers,
/// body). Execute sends the edits, Abort fails the call, Continue
/// unchanged lets it go on as captured.
///
/// Shows how many calls are paused and the time left before the call
/// continues unchanged on its own. When the call is resolved, here or
/// elsewhere (timeout, dispose), the editor moves to the next paused call;
/// when none is left it closes its route.
class BreakpointEditor extends StatefulWidget {
  /// Creates the editor of [breakpoints]' paused calls.
  const BreakpointEditor({
    required this.breakpoints,
    required this.worker,
    super.key,
    this.rawEditableLimit = defaultRawEditableLimit,
  });

  /// The paused calls.
  final BreakpointController breakpoints;

  /// Holds the bodies' JSON documents and splits text.
  final ProxieWorker worker;

  /// Bodies of at least this many bytes open read-only until "Edit
  /// anyway".
  final int rawEditableLimit;

  @override
  State<BreakpointEditor> createState() => _BreakpointEditorState();
}

class _BreakpointEditorState extends State<BreakpointEditor> {
  late StreamSubscription<List<PausedCall>> _changes;
  List<PausedCall> _pending = const [];
  PausedCall? _current;
  RequestDraft? _request;
  ResponseDraft? _response;
  Timer? _ticker;
  bool _busy = false;
  bool _closing = false;
  // The build Execute is awaiting; drafts it reads are disposed after it.
  Future<void>? _building;

  @override
  void initState() {
    super.initState();
    _pending = widget.breakpoints.pending;
    _changes = widget.breakpoints.changes.listen(_onChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _show(_pending.isEmpty ? null : _pending.first);
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    _ticker?.cancel();
    _request?.dispose();
    _response?.dispose();
    super.dispose();
  }

  void _onChanged(List<PausedCall> pending) {
    if (!mounted) return;
    setState(() {
      _pending = pending;
      if (!pending.any((p) => identical(p, _current))) {
        _show(pending.isEmpty ? null : pending.first);
      }
    });
  }

  // Edits [call]. Drafts of the previous one go after this frame, as its
  // fields are still in the tree, and after a build reading them; their
  // JSON documents close with them.
  void _show(PausedCall? call) {
    final oldRequest = _request;
    final oldResponse = _response;
    if (oldRequest != null || oldResponse != null) {
      final building = _building;
      void release() {
        oldRequest?.dispose();
        oldResponse?.dispose();
      }

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => building == null ? release() : building.whenComplete(release),
      );
    }
    _request = null;
    _response = null;
    _current = call;
    _busy = false;
    if (call == null) {
      _close();
      return;
    }
    final response = call.response;
    if (call.phase == BreakpointPhase.response) {
      // Without a response there is nothing to edit: Abort or Continue.
      if (response != null) {
        _response = ResponseDraft(widget.worker, scope: breakpointScope(call))
          ..load(response, callId: call.callId, live: true);
      }
    } else {
      _request = RequestDraft(widget.worker, scope: breakpointScope(call))
        ..load(call.request, callId: call.callId);
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _closing = false;
      // Another call paused before the frame (the same call can resolve
      // its request and pause at its response at once): keep editing.
      if (!mounted || _current != null) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  bool _isPending(PausedCall call) =>
      widget.breakpoints.pending.any((p) => identical(p, call));

  // Only the pause on screen is resolved: one resolved elsewhere, or the
  // same call paused again at its response, is left alone. False when it
  // was no longer paused.
  bool _resolve(PausedCall call, BreakpointResolution resolution) {
    if (!_isPending(call)) return false;
    widget.breakpoints.resolve(call.callId, resolution);
    return true;
  }

  static const _lateMessage =
      'The call already continued, so the edits were not sent';

  void _message(String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _execute() async {
    final call = _current;
    if (call == null || _busy) return;
    final request = _request;
    final response = _response;
    if (request == null && response == null) return;
    final problem = request?.validate() ?? response?.validate();
    if (problem != null) {
      _message(problem);
      return;
    }
    setState(() => _busy = true);
    final building = Completer<void>();
    _building = building.future;
    try {
      final resolution = request != null
          ? ExecuteRequest(await request.build())
          : ExecuteResponse(await response!.build());
      if (!_resolve(call, resolution) && mounted) _message(_lateMessage);
    } on Object catch (e, st) {
      developer.log(
        'Proxie could not read the edited body',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        _message(
          _isPending(call) ? "Couldn't read the edited body" : _lateMessage,
        );
      }
    } finally {
      building.complete();
      if (identical(_building, building.future)) _building = null;
      if (mounted && identical(_current, call)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = _current;
    if (call == null) {
      return Scaffold(appBar: AppBar(title: const Text('Breakpoint')));
    }
    final theme = Theme.of(context);
    final index = _pending.indexWhere((p) => identical(p, call));
    // The call on screen is always one of the pending ones.
    assert(index >= 0, 'The edited call is not pending');
    final deadline =
        widget.breakpoints.deadlineOf(call.callId) ??
        call.pausedAt.add(widget.breakpoints.timeout);
    final left = deadline.difference(DateTime.now());
    final seconds = left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
    final request = _request;
    final response = _response;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          call.phase == BreakpointPhase.response
              ? 'Response breakpoint'
              : 'Request breakpoint',
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColoredBox(
            color: theme.colorScheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${call.request.method} ${call.request.url}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 16,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      Text(
                        '${index + 1} of ${_pending.length} paused',
                        style: theme.textTheme.labelMedium,
                      ),
                      Text(
                        'Continues unchanged in $seconds s',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: KeyedSubtree(
              key: ObjectKey(call),
              child: request != null
                  ? RequestForm(
                      draft: request,
                      worker: widget.worker,
                      rawEditableLimit: widget.rawEditableLimit,
                    )
                  : response != null
                  ? ResponseEditor(
                      draft: response,
                      worker: widget.worker,
                      rawEditableLimit: widget.rawEditableLimit,
                      useVerb: 'sending',
                    )
                  : const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No response to edit. Abort the call or let it '
                          'continue unchanged.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
            ),
          ),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _resolve(call, const Abort()),
                    child: const Text('Abort'),
                  ),
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _resolve(call, const ContinueUnchanged()),
                    child: const Text('Continue unchanged'),
                  ),
                  FilledButton(
                    onPressed: _busy || (request == null && response == null)
                        ? null
                        : () => unawaited(_execute()),
                    child: const Text('Execute'),
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

/// Puts a [BreakpointEditor] on the inspector's navigator (see
/// [ProxieInspector.navigatorOf]) when calls are paused in [breakpoints]:
/// at once if some are when it is built, and whenever a new call pauses
/// while no editor of its own is up. Never stacks a second editor.
///
/// While calls stay paused with no editor up (the user went back from it),
/// a bar under [child] says how many and opens the editor again.
class BreakpointHost extends StatefulWidget {
  /// Wraps [child], the inspector's layout.
  const BreakpointHost({
    required this.breakpoints,
    required this.worker,
    required this.child,
    super.key,
    this.rawEditableLimit = defaultRawEditableLimit,
    this.onEditorLeft,
  });

  /// Called when the user leaves an editor while calls are still paused.
  final VoidCallback? onEditorLeft;

  /// The paused calls.
  final BreakpointController breakpoints;

  /// Passed to the editor.
  final ProxieWorker worker;

  /// Passed to the editor.
  final int rawEditableLimit;

  /// The inspector's layout.
  final Widget child;

  @override
  State<BreakpointHost> createState() => _BreakpointHostState();
}

class _BreakpointHostState extends State<BreakpointHost> {
  late StreamSubscription<List<PausedCall>> _changes;
  List<PausedCall> _known = const [];
  Route<void>? _route;

  @override
  void initState() {
    super.initState();
    _known = widget.breakpoints.pending;
    _changes = widget.breakpoints.changes.listen(_onChanged);
    if (_known.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open());
    }
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }

  void _onChanged(List<PausedCall> pending) {
    final arrived = pending.any((p) => !_known.any((k) => identical(k, p)));
    setState(() => _known = pending);
    if (arrived) _open();
  }

  bool get _editorUp => _route?.isActive ?? false;

  void _open() {
    // A route removed without completing counts as gone too.
    if (!mounted || _editorUp || widget.breakpoints.pending.isEmpty) {
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => BreakpointEditor(
        breakpoints: widget.breakpoints,
        worker: widget.worker,
        rawEditableLimit: widget.rawEditableLimit,
      ),
    );
    _route = route;
    unawaited(
      ProxieInspector.navigatorOf(context).push(route).whenComplete(() {
        if (identical(_route, route)) _route = null;
        // The editor closes itself only once nothing is paused.
        if (widget.breakpoints.pending.isNotEmpty) widget.onEditorLeft?.call();
        if (mounted) setState(() {});
      }),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final count = _known.length;
    final theme = Theme.of(context);
    // Always a Column, so the shell keeps its state when the bar comes.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: widget.child),
        if (count > 0 && !_editorUp)
          Material(
            color: theme.colorScheme.tertiaryContainer,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.pause_circle_outline,
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '$count paused',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ),
                    TextButton(onPressed: _open, child: const Text('Open')),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
