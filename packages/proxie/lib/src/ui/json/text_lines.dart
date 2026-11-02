import 'dart:convert';
import 'dart:typed_data';

import 'package:proxie/src/json/json_document.dart';
import 'package:proxie/src/worker/worker.dart';

/// Longest piece of a line the raw text view lays out as one paragraph.
const int rawLineLimit = 2000;

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09;

/// Splits [text] into pieces of at most [maxChunk] UTF-16 code units, so a
/// large body can be laid out lazily. The pieces join back to [text]
/// exactly (a copied selection across them adds or drops nothing).
///
/// A piece ends after the last line break in its window, else after the
/// last space or tab in the window's second half, else at the window's end;
/// it never ends between the two halves of a surrogate pair.
List<String> textChunks(String text, {int maxChunk = rawLineLimit}) {
  assert(maxChunk >= 2, 'a surrogate pair needs two code units');
  if (text.length <= maxChunk) return [text];
  final chunks = <String>[];
  var start = 0;
  while (text.length - start > maxChunk) {
    final limit = start + maxChunk;
    // Searches this window only: a scan back to the text's start would make
    // a long single line quadratic.
    var end = limit;
    var lineEnd = -1;
    for (var i = limit - 1; i >= start; i--) {
      if (text.codeUnitAt(i) == 0x0A) {
        lineEnd = i + 1;
        break;
      }
    }
    if (lineEnd > start) {
      end = lineEnd;
    } else {
      for (var i = limit - 1; i > start + maxChunk ~/ 2; i--) {
        if (_isSpace(text.codeUnitAt(i))) {
          end = i + 1;
          break;
        }
      }
      if (end == limit && _isHighSurrogate(text.codeUnitAt(end - 1))) end--;
    }
    chunks.add(text.substring(start, end));
    start = end;
  }
  chunks.add(text.substring(start));
  return chunks;
}

/// Splits [text] into its lines, each keeping its line break; a line longer
/// than [maxLine] is cut further by [textChunks]. The pieces join back to
/// [text] exactly, and none ends inside a surrogate pair.
List<String> textLines(String text, {int maxLine = rawLineLimit}) {
  final lines = <String>[];
  var start = 0;
  while (start < text.length) {
    final lineBreak = text.indexOf('\n', start);
    final end = lineBreak == -1 ? text.length : lineBreak + 1;
    final line = text.substring(start, end);
    if (line.length <= maxLine) {
      lines.add(line);
    } else {
      lines.addAll(textChunks(line, maxChunk: maxLine));
    }
    start = end;
  }
  if (lines.isEmpty) lines.add('');
  return lines;
}

/// Decodes [bytes] and splits the text with [textLines] inside the worker,
/// so a large body never decodes or indents on the UI isolate. Null when
/// the bytes are not valid text.
class RawTextLines extends WorkerCommand<List<String>?> {
  /// Creates a command that splits [bytes] into lines.
  const RawTextLines(
    this.bytes, {
    this.prettyJson = false,
    this.latin1 = false,
  });

  /// The body.
  final Uint8List bytes;

  /// Whether to indent [bytes] by two spaces first when they parse as JSON;
  /// they are split as they are when they do not.
  final bool prettyJson;

  /// Whether [bytes] are ISO-8859-1 rather than UTF-8.
  final bool latin1;

  @override
  Future<List<String>?> execute(WorkerContext ctx) async {
    var source = bytes;
    if (prettyJson) {
      final doc = JsonDocument.tryParse(bytes);
      if (doc.parseError == null) source = doc.encode(pretty: true);
    }
    final String text;
    try {
      text = latin1
          ? const Latin1Decoder().convert(source)
          : utf8.decode(source);
    } on FormatException {
      return null;
    }
    return textLines(text);
  }
}
