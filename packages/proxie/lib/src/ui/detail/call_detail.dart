import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/ui/detail/body_view.dart';
import 'package:proxie/src/ui/detail/copy_actions.dart';
import 'package:proxie/src/ui/detail/headers_tab.dart';
import 'package:proxie/src/ui/detail/timing_tab.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';
import 'package:proxie/src/ui/sections.dart';
import 'package:proxie/src/ui/theme.dart';
import 'package:proxie/src/worker/commands.dart';
import 'package:proxie/src/worker/worker.dart';

/// The detail of one call: a header (method, URL, status, actions) over the
/// tabs Response, Request, Headers, Timing and the registered
/// [ProxieDetailTab]s that apply to it.
///
/// Loads the full call from [worker] and loads it again whenever [calls]
/// reports a change to it, so a call opened while pending shows its response
/// once it arrives.
class CallDetail extends StatefulWidget {
  /// Creates the detail of call [callId].
  const CallDetail({
    required this.worker,
    required this.calls,
    required this.callId,
    required this.renderCap,
    super.key,
    this.actions = const ProxieDetailActions(),
    this.jsonBuilder,
  });

  /// Where the call is stored.
  final ProxieWorker worker;

  /// Snapshots of calls as they change (the engine's call stream).
  final Stream<ProxieCall> calls;

  /// The id of the call shown.
  final String callId;

  /// Bodies larger than this many bytes are shown only on request.
  final int renderCap;

  /// Targets of the rule and resend buttons; null ones are hidden.
  final ProxieDetailActions actions;

  /// Builds JSON bodies; null shows them as a read-only [JsonBodyView].
  final BodyJsonBuilder? jsonBuilder;

  @override
  State<CallDetail> createState() => _CallDetailState();
}

class _CallDetailState extends State<CallDetail> with TickerProviderStateMixin {
  StreamSubscription<ProxieCall>? _sub;
  ProxieCall? _call;
  bool _loaded = false;
  Object? _error;
  bool _fetching = false;
  bool _again = false;

  // Tab selection by id, so it survives tabs coming and going.
  TabController? _tabController;
  List<String> _tabIds = const [];
  String _selectedTab = 'response';

  // Bodies ('request', 'response') whose "Show" was tapped.
  final Set<String> _revealed = {};

  // Registered tabs whose appliesTo threw; each is reported once.
  final Set<String> _reportedTabs = {};

  @override
  void initState() {
    super.initState();
    _listen();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(CallDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.calls != widget.calls) {
      unawaited(_sub?.cancel());
      _listen();
    }
    if (oldWidget.worker != widget.worker ||
        oldWidget.callId != widget.callId) {
      _call = null;
      _loaded = false;
      _error = null;
      _revealed.clear();
      unawaited(_load());
    }
  }

  void _listen() {
    _sub = widget.calls.listen(
      (c) {
        if (c.id == widget.callId) unawaited(_load());
      },
      // The stream belongs to the engine; its errors are not ours to show.
      onError: (Object e, StackTrace st) => developer.log(
        'Proxie call stream error',
        name: 'proxie',
        error: e,
        stackTrace: st,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _tabController?.dispose();
    super.dispose();
  }

  TabController _controllerFor(List<String> ids) {
    final current = _tabController;
    if (current != null && listEquals(ids, _tabIds)) return current;
    var index = ids.indexOf(_selectedTab);
    // The selected tab went away: keep the position, clamped.
    if (index < 0) index = (current?.index ?? 0).clamp(0, ids.length - 1);
    _tabIds = ids;
    _selectedTab = ids[index];
    final next = TabController(
      length: ids.length,
      initialIndex: index,
      vsync: this,
    )..addListener(_onTabChanged);
    _tabController = next;
    if (current != null) {
      current.removeListener(_onTabChanged);
      // The old tab bar lets go of it in this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
    }
    return next;
  }

  void _onTabChanged() {
    final c = _tabController;
    if (c != null) _selectedTab = _tabIds[c.index];
  }

  Widget _body(String side, ProxieBody body) => BodyView(
    key: ValueKey('$side-body'),
    worker: widget.worker,
    body: body,
    renderCap: widget.renderCap,
    revealed: _revealed.contains(side),
    onShow: () => setState(() => _revealed.add(side)),
    jsonBuilder:
        widget.jsonBuilder ??
        (context, body) => JsonBodyView(
          key: ValueKey('$side-json'),
          worker: widget.worker,
          callId: widget.callId,
          which: side,
          body: body,
        ),
  );

  // One fetch at a time; changes arriving meanwhile cause one more fetch.
  Future<void> _load() async {
    if (_fetching) {
      _again = true;
      return;
    }
    _fetching = true;
    try {
      do {
        _again = false;
        final id = widget.callId;
        final worker = widget.worker;
        try {
          final call = await worker.run(GetCall(id));
          if (!mounted) return;
          if (id != widget.callId || worker != widget.worker) {
            _again = true;
            continue;
          }
          setState(() {
            _call = call;
            _loaded = true;
            _error = null;
          });
        } on Object catch (e, st) {
          // The host app must never crash because the worker failed.
          developer.log(
            'Proxie could not load call $id',
            name: 'proxie',
            error: e,
            stackTrace: st,
          );
          if (!mounted) return;
          setState(() => _error = e);
        }
      } while (_again);
    } finally {
      _fetching = false;
    }
  }

  void _retry() {
    setState(() => _error = null);
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    final call = _call;
    if (call == null) {
      if (_error != null) {
        return _Message("Couldn't load this request", onRetry: _retry);
      }
      // Loading takes one worker round trip; nothing animates meanwhile, so
      // a detail whose worker is stuck never keeps frames scheduled.
      if (!_loaded) return const SizedBox.shrink();
      return const _Message('This request is no longer available');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null) _ErrorBar(onRetry: _retry),
        _Header(call: call, actions: widget.actions),
        Expanded(child: _tabs(context, call)),
      ],
    );
  }

  Widget _tabs(BuildContext context, ProxieCall call) {
    final tabs = <(String, String, WidgetBuilder)>[
      ('response', 'Response', (_) => _responseTab(call)),
      ('request', 'Request', (_) => _body('request', call.request.body)),
      ('headers', 'Headers', (_) => HeadersTab(call: call)),
      ('timing', 'Timing', (_) => TimingTab(call: call)),
      for (final tab in ProxieSections.detailTabs)
        if (_applies(tab, call))
          ('custom:${tab.id}', tab.label, (c) => tab.build(c, call)),
    ];
    final controller = _controllerFor([for (final t in tabs) t.$1]);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabBar(
          controller: controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final t in tabs) Tab(height: 40, text: t.$2)],
        ),
        Expanded(
          child: TabBarView(
            controller: controller,
            children: [for (final t in tabs) Builder(builder: t.$3)],
          ),
        ),
      ],
    );
  }

  bool _applies(ProxieDetailTab tab, ProxieCall call) {
    try {
      return tab.appliesTo(call);
    } on Object catch (e, st) {
      // A faulty registered tab is left out, never fatal, and reported once
      // rather than on every refresh.
      if (!_reportedTabs.add(tab.id)) return false;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: e,
          stack: st,
          library: 'proxie',
          context: ErrorDescription(
            'while checking whether detail tab "${tab.id}" applies',
          ),
        ),
      );
      return false;
    }
  }

  Widget _responseTab(ProxieCall call) {
    final response = call.response;
    final error = call.error;
    if (response == null) {
      if (error != null) return _ErrorView(error);
      return const _Message('Waiting for response…', busy: true);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (error != null) _ErrorView(error, compact: true),
        Expanded(child: _body('response', response.body)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.call, required this.actions});

  final ProxieCall call;
  final ProxieDetailActions actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ProxieColors.of(context);
    final response = call.response;
    final error = call.error;
    final status = error != null
        ? (response == null ? error.type : '${response.statusCode}')
        : response == null
        ? 'Pending'
        : [response.statusCode, ?response.reasonPhrase].join(' ');
    final statusColor = colors.statusColor(
      response?.statusCode,
      error: error != null,
    );
    final onMapLocal = actions.onMapLocal;
    final onBreakpoint = actions.onBreakpoint;
    final onEditResend = actions.onEditResend;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      call.request.method,
                      style: proxieMono(theme.textTheme.labelLarge)?.copyWith(
                        color: colors.methodColor(call.request.method),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Narrow when every action button is shown.
                    Flexible(
                      child: Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: proxieMono(
                          theme.textTheme.labelLarge,
                        )?.copyWith(color: statusColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SelectableText(
                  call.request.url.toString(),
                  // Without minLines it reserves all three lines.
                  minLines: 1,
                  maxLines: 3,
                  style: proxieMono(theme.textTheme.bodySmall),
                ),
              ],
            ),
          ),
          if (onMapLocal != null && response != null)
            IconButton(
              tooltip: 'Map Local from this response',
              icon: const Icon(Icons.file_download_outlined),
              onPressed: () => onMapLocal(call),
            ),
          if (onBreakpoint != null)
            IconButton(
              tooltip: 'Breakpoint on this URL',
              icon: const Icon(Icons.pause_circle_outline),
              onPressed: () => onBreakpoint(call),
            ),
          if (onEditResend != null)
            IconButton(
              tooltip: 'Edit & resend',
              icon: const Icon(Icons.replay),
              onPressed: () => onEditResend(call),
            ),
          CopyMenu(call: call),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView(this.error, {this.compact = false});

  final ProxieError error;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final box = ColoredBox(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          '${error.type}: ${error.message}',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
    if (compact) return box;
    return Align(alignment: Alignment.topCenter, child: box);
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry, this.busy = false});

  final String text;
  final VoidCallback? onRetry;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy) ...[
              Icon(
                Icons.hourglass_empty,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
            ],
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                "Couldn't refresh this request",
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
