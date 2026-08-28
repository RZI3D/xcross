import 'dart:convert';

final class SwiftPmRemoteBinaryTarget {
  const SwiftPmRemoteBinaryTarget({
    required this.name,
    required this.url,
    required this.checksum,
    required this.start,
    required this.end,
  });

  final String name;
  final Uri url;
  final String checksum;
  final int start;
  final int end;
}

abstract final class SwiftPmBinaryTargetManifest {
  static final _checksumPattern = RegExp(r'^[0-9a-fA-F]{64}$');
  static const _callName = '.binaryTarget';

  static List<SwiftPmRemoteBinaryTarget> discover(String source) {
    final code = _swiftCodeMask(source);
    final targets = <SwiftPmRemoteBinaryTarget>[];

    for (var start = 0; start < source.length; start++) {
      if (!code[start] || !source.startsWith(_callName, start)) continue;
      final nameEnd = start + _callName.length;
      if (!_isCodeRange(code, start, nameEnd)) continue;
      if (nameEnd < source.length &&
          _isIdentifier(source.codeUnitAt(nameEnd))) {
        continue;
      }

      var opening = nameEnd;
      while (opening < source.length &&
          _isWhitespace(source.codeUnitAt(opening))) {
        opening++;
      }
      if (opening == source.length ||
          source[opening] != '(' ||
          !code[opening]) {
        continue;
      }
      final closing = _matchingParenthesis(source, code, opening);
      if (closing == null) continue;

      final arguments = _directLiteralArguments(
        source,
        code,
        opening + 1,
        closing,
      );
      final name = arguments['name'];
      final urlText = arguments['url'];
      final checksum = arguments['checksum'];
      final url = urlText == null ? null : Uri.tryParse(urlText);
      final eligibleScheme = url?.scheme == 'https' || url?.scheme == 'http';
      final eligibleUrl =
          url != null &&
          eligibleScheme &&
          url.hasAuthority &&
          url.host.isNotEmpty &&
          url.userInfo.isEmpty &&
          url.path.toLowerCase().endsWith('.zip');
      if (name != null &&
          url != null &&
          checksum != null &&
          eligibleUrl &&
          _checksumPattern.hasMatch(checksum)) {
        targets.add(
          SwiftPmRemoteBinaryTarget(
            name: name,
            url: url,
            checksum: checksum,
            start: start,
            end: closing + 1,
          ),
        );
      }
      start = closing;
    }
    return targets;
  }

  static String rewriteToLocalPaths(
    String source,
    Map<SwiftPmRemoteBinaryTarget, String> relativePaths,
  ) {
    final discovered = discover(source);
    for (final requested in relativePaths.keys) {
      final belongs = discovered.any(
        (target) =>
            target.start == requested.start &&
            target.end == requested.end &&
            target.name == requested.name &&
            target.url == requested.url &&
            target.checksum == requested.checksum,
      );
      if (!belongs) {
        throw ArgumentError.value(
          requested,
          'relativePaths',
          'Target not in source',
        );
      }
    }

    var rewritten = source;
    final replacements = relativePaths.entries.toList()
      ..sort((left, right) => right.key.start.compareTo(left.key.start));
    for (final entry in replacements) {
      final target = entry.key;
      final replacement =
          '.binaryTarget(name: ${jsonEncode(target.name)}, path: ${jsonEncode(entry.value)})';
      rewritten = rewritten.replaceRange(target.start, target.end, replacement);
    }
    return rewritten;
  }
}

Map<String, String> _directLiteralArguments(
  String source,
  List<bool> code,
  int start,
  int end,
) {
  final arguments = <String, String>{};
  var segmentStart = start;
  var round = 0;
  var square = 0;
  var curly = 0;

  void parseSegment(int segmentEnd) {
    var cursor = segmentStart;
    while (cursor < segmentEnd && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    final labelStart = cursor;
    while (cursor < segmentEnd && _isIdentifier(source.codeUnitAt(cursor))) {
      cursor++;
    }
    final label = source.substring(labelStart, cursor);
    if (label != 'name' && label != 'url' && label != 'checksum') return;
    while (cursor < segmentEnd && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor == segmentEnd || source[cursor] != ':') return;
    cursor++;
    while (cursor < segmentEnd && _isWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    final literal = _parseStringLiteral(source, cursor, segmentEnd);
    if (literal != null) arguments[label] = literal;
  }

  for (var index = start; index < end; index++) {
    if (!code[index]) continue;
    switch (source[index]) {
      case '(':
        round++;
      case ')':
        round--;
      case '[':
        square++;
      case ']':
        square--;
      case '{':
        curly++;
      case '}':
        curly--;
      case ',' when round == 0 && square == 0 && curly == 0:
        parseSegment(index);
        segmentStart = index + 1;
    }
  }
  parseSegment(end);
  return arguments;
}

String? _parseStringLiteral(String source, int start, int segmentEnd) {
  var hashes = 0;
  while (start + hashes < segmentEnd && source[start + hashes] == '#') {
    hashes++;
  }
  final quote = start + hashes;
  if (quote >= segmentEnd || source[quote] != '"') return null;
  final multiline = source.startsWith('"""', quote);
  final openingLength = multiline ? 3 : 1;
  final closing = '${multiline ? '"""' : '"'}${'#' * hashes}';
  final contentStart = quote + openingLength;
  var contentEnd = segmentEnd;
  while (contentEnd > contentStart &&
      _isWhitespace(source.codeUnitAt(contentEnd - 1))) {
    contentEnd--;
  }
  if (!source.substring(start, contentEnd).endsWith(closing)) return null;
  final valueEnd = contentEnd - closing.length;
  if (valueEnd < contentStart) return null;
  var value = source.substring(contentStart, valueEnd);
  final rawEscape = '\\${'#' * hashes}';
  final interpolation = '$rawEscape(';
  if (value.contains(interpolation) ||
      hashes > 0 && value.contains(rawEscape)) {
    return null;
  }
  if (multiline) {
    final closingLineStart = source.lastIndexOf('\n', valueEnd - 1) + 1;
    if (source.substring(closingLineStart, valueEnd).trim().isEmpty &&
        closingLineStart != valueEnd) {
      return null;
    }
    if (value.startsWith('\r\n')) {
      value = value.substring(2);
    } else if (value.startsWith('\n')) {
      value = value.substring(1);
    }
    if (value.endsWith('\r\n')) {
      value = value.substring(0, value.length - 2);
    } else if (value.endsWith('\n')) {
      value = value.substring(0, value.length - 1);
    }
  }
  if (hashes > 0) return value;
  try {
    return jsonDecode('"${value.replaceAll(r'\/', '/')}"') as String;
  } on FormatException {
    return null;
  }
}

List<bool> _swiftCodeMask(String source) {
  final code = List<bool>.filled(source.length, true);
  var index = 0;
  while (index < source.length) {
    if (source.startsWith('//', index)) {
      final start = index;
      index += 2;
      while (index < source.length && source[index] != '\n') {
        index++;
      }
      _mask(code, start, index);
      continue;
    }
    if (source.startsWith('/*', index)) {
      final start = index;
      var depth = 1;
      index += 2;
      while (index < source.length && depth > 0) {
        if (source.startsWith('/*', index)) {
          depth++;
          index += 2;
        } else if (source.startsWith('*/', index)) {
          depth--;
          index += 2;
        } else {
          index++;
        }
      }
      _mask(code, start, index);
      continue;
    }

    var hashes = 0;
    while (index + hashes < source.length && source[index + hashes] == '#') {
      hashes++;
    }
    final quote = index + hashes;
    if (quote < source.length && source[quote] == '"') {
      final start = index;
      final multiline = source.startsWith('"""', quote);
      final quoteCount = multiline ? 3 : 1;
      index = quote + quoteCount;
      final closing = '${multiline ? '"""' : '"'}${'#' * hashes}';
      while (index < source.length) {
        if (source.startsWith(closing, index) &&
            (hashes == 0
                ? !_isEscaped(source, index)
                : !_isRawEscapedDelimiter(source, index, hashes))) {
          index += closing.length;
          break;
        }
        index++;
      }
      _mask(code, start, index);
      continue;
    }
    index++;
  }
  return code;
}

int? _matchingParenthesis(String source, List<bool> code, int opening) {
  var depth = 0;
  for (var index = opening; index < source.length; index++) {
    if (!code[index]) continue;
    if (source[index] == '(') depth++;
    if (source[index] == ')' && --depth == 0) return index;
  }
  return null;
}

bool _isCodeRange(List<bool> code, int start, int end) {
  for (var index = start; index < end; index++) {
    if (!code[index]) return false;
  }
  return true;
}

bool _isRawEscapedDelimiter(String source, int index, int hashes) {
  final escapeStart = index - hashes - 1;
  return escapeStart >= 0 &&
      source[escapeStart] == r'\' &&
      source.substring(escapeStart + 1, index) == '#' * hashes;
}

bool _isEscaped(String source, int index) {
  var slashes = 0;
  for (
    var cursor = index - 1;
    cursor >= 0 && source[cursor] == r'\';
    cursor--
  ) {
    slashes++;
  }
  return slashes.isOdd;
}

bool _isIdentifier(int character) =>
    character >= 48 && character <= 57 ||
    character >= 65 && character <= 90 ||
    character >= 97 && character <= 122 ||
    character == 95;

bool _isWhitespace(int character) =>
    character == 0x20 ||
    character == 0x09 ||
    character == 0x0a ||
    character == 0x0d;

void _mask(List<bool> code, int start, int end) {
  for (var index = start; index < end; index++) {
    code[index] = false;
  }
}
