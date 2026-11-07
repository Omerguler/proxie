// What HTTP allows in methods, header names and header values, as `dart:io`
// checks them. Pure Dart, so the editors (web included) refuse what an
// adapter would throw on.

const _separators = '()<>@,;:\\"/[]?={} \t';

/// Whether every character of [s] is an HTTP token character (RFC 2616:
/// visible US-ASCII except separators), as `dart:io` checks methods and
/// header names.
bool isHttpToken(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c <= 31 || c >= 127 || _separators.contains(s[i])) return false;
  }
  return true;
}

/// The index of the first character `dart:io` refuses to send in a header
/// value (anything but US-ASCII from space up, DEL included, or tab), or
/// -1 when there is none.
int unsendableHeaderChar(String value) {
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (!((c > 31 && c < 128) || c == 9)) return i;
  }
  return -1;
}

/// The index of the first character a received header value cannot hold
/// (CR, LF or NUL), or -1 when there is none.
int unreceivableHeaderChar(String value) {
  for (var i = 0; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    if (c == 13 || c == 10 || c == 0) return i;
  }
  return -1;
}
