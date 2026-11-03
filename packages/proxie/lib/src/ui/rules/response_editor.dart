import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/core/masking.dart' show kMask;
import 'package:proxie/src/json/json_commands.dart' show JsonBodySide;
import 'package:proxie/src/model/response.dart';
import 'package:proxie/src/ui/rules/message_draft.dart';
import 'package:proxie/src/worker/worker.dart';

/// The scope (see `OpenJson.scope`) rule editors open captured bodies in,
/// so their edits never reach the read-only detail.
const String ruleEditorScope = 'rule-editor';

/// The response a [ResponseEditor] edits: status, headers and body (see
/// [MessageDraft]). [build] gives the response as edited.
class ResponseDraft extends MessageDraft {
  /// Creates an empty 200 response; [worker] holds the body's JSON
  /// document, opened in [scope].
  ResponseDraft(super.worker, {super.scope = ruleEditorScope})
    : super(side: JsonBodySide.response);

  /// The status code, as typed.
  final TextEditingController status = TextEditingController(text: '200');

  int? _loadedStatus;
  String? _reason;

  /// Starts over from [response]; see [MessageDraft.loadMessage] for
  /// [callId], [captured] and [live].
  void load(
    ProxieResponse response, {
    String? callId,
    bool captured = false,
    bool live = false,
  }) {
    status.text = '${response.statusCode}';
    _loadedStatus = response.statusCode;
    _reason = response.reasonPhrase;
    loadMessage(
      response.headers,
      response.body,
      callId: callId,
      captured: captured,
      live: live,
    );
  }

  /// Why the response cannot be used yet, or null.
  String? validate() {
    final code = int.tryParse(status.text.trim());
    if (code == null || code < 100 || code > 599) {
      return 'Status must be a number from 100 to 599';
    }
    // The app receives these headers: the received-value rule applies.
    return validateHeaders(received: true) ?? validateBody();
  }

  /// The response as edited; check [validate] first. Throws when the
  /// edited tree cannot be encoded.
  Future<ProxieResponse> build() async {
    final code = int.parse(status.text.trim());
    return ProxieResponse(
      statusCode: code,
      reasonPhrase: code == _loadedStatus ? _reason : null,
      headers: buildHeaders(),
      body: await buildBody(),
    );
  }

  @override
  void dispose() {
    status.dispose();
    super.dispose();
  }
}

/// Edits [draft]'s status, headers (add, edit, delete) and body, as a JSON
/// tree or raw text.
class ResponseEditor extends StatelessWidget {
  /// Creates the editor of [draft].
  const ResponseEditor({
    required this.draft,
    required this.worker,
    super.key,
    this.rawEditableLimit = defaultRawEditableLimit,
    this.onPresets,
    this.onSaveAsPreset,
    this.useVerb = 'saving',
  });

  /// The response edited.
  final ResponseDraft draft;

  /// Splits the body into lines.
  final ProxieWorker worker;

  /// Bodies of at least this many bytes open read-only until "Edit
  /// anyway".
  final int rawEditableLimit;

  /// Opens the preset picker; hidden when null.
  final VoidCallback? onPresets;

  /// Saves the response as a custom preset; hidden when null.
  final VoidCallback? onSaveAsPreset;

  /// What the notices ask to fix things before, e.g. "saving".
  final String useVerb;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: draft,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 96,
                child: TextField(
                  key: const ValueKey('response-status'),
                  controller: draft.status,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: 'Status'),
                ),
              ),
              if (onPresets != null)
                TextButton.icon(
                  onPressed: onPresets,
                  icon: const Icon(Icons.library_books_outlined),
                  label: const Text('Presets'),
                ),
              if (onSaveAsPreset != null)
                TextButton.icon(
                  onPressed: onSaveAsPreset,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Save as preset'),
                ),
            ],
          ),
        ),
        MessageNotices(draft: draft, useVerb: useVerb),
        MessageHeaders(
          key: ValueKey(draft.generation),
          draft: draft,
          expanded: draft.headers.any((h) => h.value.text == kMask),
        ),
        const Divider(height: 1),
        Expanded(
          child: MessageBody(
            draft: draft,
            worker: worker,
            rawEditableLimit: rawEditableLimit,
            binaryHint: onPresets == null
                ? null
                : 'Pick a preset to replace it.',
          ),
        ),
      ],
    ),
  );
}
