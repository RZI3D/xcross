import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:posix/posix.dart' as posix;
import 'package:tar/tar.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Pure-Dart replacements for shell `curl`/`tar`: streaming HTTP download and
/// streaming `.tar.gz` extraction with no external processes — aside from
/// `chmod`, which restores unix exec bits that `dart:io` cannot set itself.

/// Open [url] with retry, following redirects, throwing [XcrossError] on any
/// non-2xx status. Returns the live, undrained response stream.
Future<HttpClientResponse> _openStream(
  HttpClient client,
  String url, {
  required int maxAttempts,
  required Duration retryDelay,
}) async {
  Object? lastError;
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.followRedirects = true;
      request.maxRedirects = 10;
      final response = await request.close();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.drain<void>();
        throw XcrossError(
          'download failed: HTTP ${response.statusCode} for $url',
        );
      }
      return response;
    } catch (e) {
      lastError = e;
      if (attempt == maxAttempts) break;
      await Future<void>.delayed(retryDelay);
    }
  }
  throw XcrossError(
    'download failed after $maxAttempts attempts: $url'
    '${lastError == null ? '' : ' ($lastError)'}',
  );
}

/// Stream [url] to [dest] (pure Dart; replaces `curl -L --fail -o`).
///
/// Shows a live download-progress line on stdout (bytes, percent, rate). Pass
/// [label] to override the display name (defaults to the URL's file name);
/// set [showProgress] to `false` to silence it.
Future<void> downloadToFile(
  String url,
  File dest, {
  int maxAttempts = 4,
  Duration retryDelay = const Duration(seconds: 2),
  String? label,
  bool showProgress = true,
}) async {
  final client = HttpClient();
  try {
    final response = await _openStream(
      client,
      url,
      maxAttempts: maxAttempts,
      retryDelay: retryDelay,
    );
    await dest.parent.create(recursive: true);
    final reporter = showProgress
        ? _DownloadProgress(
            label ?? _labelFromUrl(url),
            response.contentLength,
          )
        : null;
    final sink = dest.openWrite();
    try {
      await sink.addStream(_withProgress(response, reporter));
      await sink.flush();
    } finally {
      await sink.close();
    }
    reporter?.finish();
  } finally {
    client.close(force: true);
  }
}

/// A symlink/hardlink to create once all regular files have been written.
class _PendingLink {
  const _PendingLink(this.path, this.target);

  final String path;
  final String target;
}

/// Stream-download [url] and extract its gzip-compressed tar into [dest]
/// (pure Dart; replaces `curl -fsSL | tar -xz`).
///
/// [stripComponents] drops that many leading path segments (like
/// `tar --strip-components`). [keep], if provided, receives each entry's
/// stripped relative path and returns whether to extract it — used for
/// selective subtree extraction. Unix modes carrying exec bits are restored
/// via `chmod`; symlinks and hardlinks are recreated after all files exist.
///
/// A live download-progress line is shown on stdout while bytes are being
/// pulled from the network (before gzip/tar decode). Pass [label] to override
/// the display name; set [showProgress] to `false` to silence it.
Future<void> downloadAndExtractTarGz({
  required String url,
  required Directory dest,
  int stripComponents = 0,
  bool Function(String relPath)? keep,
  int maxAttempts = 4,
  Duration retryDelay = const Duration(seconds: 2),
  String? label,
  bool showProgress = true,
}) async {
  final client = HttpClient();
  final destRoot = p.normalize(dest.path);
  final pendingLinks = <_PendingLink>[];
  TarReader? reader;
  _DownloadProgress? reporter;
  try {
    final response = await _openStream(
      client,
      url,
      maxAttempts: maxAttempts,
      retryDelay: retryDelay,
    );
    reporter = showProgress
        ? _DownloadProgress(
            label ?? _labelFromUrl(url),
            response.contentLength,
          )
        : null;
    reader = TarReader(
      _withProgress(response, reporter).transform(gzip.decoder),
    );
    while (await reader.moveNext()) {
      final entry = reader.current;
      final header = entry.header;
      final rel = _strip(header.name, stripComponents);
      if (rel == null || rel.isEmpty || rel == '.') continue;
      if (keep != null && !keep(rel)) continue;

      final outPath = p.normalize(p.join(destRoot, rel));
      // Path-traversal guard: never escape [dest].
      if (outPath != destRoot && !p.isWithin(destRoot, outPath)) continue;

      final type = entry.type;
      if (type == TypeFlag.dir) {
        await Directory(outPath).create(recursive: true);
      } else if (type == TypeFlag.reg || type == TypeFlag.regA) {
        await Directory(p.dirname(outPath)).create(recursive: true);
        final sink = File(outPath).openWrite();
        try {
          await sink.addStream(entry.contents);
          await sink.flush();
        } finally {
          await sink.close();
        }
        // Restore exec bits via libc chmod (FFI) — no subprocess. posix is a
        // no-op stub on non-POSIX hosts, so guard with isPosixSupported.
        final mode = header.mode;
        if (mode != 0 && (mode & 0x49) != 0 && posix.isPosixSupported) {
          posix.chmodWithMode(outPath, mode);
        }
      } else if (type == TypeFlag.symlink) {
        final target = header.linkName;
        if (target != null && target.isNotEmpty) {
          pendingLinks.add(_PendingLink(outPath, target));
        }
      } else if (type == TypeFlag.link) {
        final target = header.linkName;
        if (target != null && target.isNotEmpty) {
          final targetRel = _strip(target, stripComponents) ?? target;
          pendingLinks.add(
            _PendingLink(outPath, p.join(destRoot, targetRel)),
          );
        }
      }
      // Other entry types (PAX/GNU metadata) are consumed by the reader.
    }

    for (final link in pendingLinks) {
      await Directory(p.dirname(link.path)).create(recursive: true);
      final existing = Link(link.path);
      final linkExists = existing.existsSync();
      if (linkExists) existing.deleteSync();
      await Link(link.path).create(link.target);
    }
    reporter?.finish();
  } finally {
    await reader?.cancel();
    client.close(force: true);
  }
}

/// Wrap [source] so [reporter] observes byte counts without changing the
/// stream's contents. Returns the source unchanged when [reporter] is null.
Stream<List<int>> _withProgress(
  Stream<List<int>> source,
  _DownloadProgress? reporter,
) {
  if (reporter == null) return source;
  return source.map((chunk) {
    reporter.add(chunk.length);
    return chunk;
  });
}

/// Best-effort file-name from [url] for display in the progress line.
String _labelFromUrl(String url) {
  try {
    final segs = Uri.parse(url).pathSegments;
    for (var i = segs.length - 1; i >= 0; i--) {
      if (segs[i].isNotEmpty) return segs[i];
    }
  } catch (_) {}
  return url;
}

/// Live download-progress line. Prints `\r`-overwriting updates on a TTY
/// (bytes / total, percent, rate); on a non-TTY (piped/logged) it emits
/// occasional plain lines so logs stay readable. [total] is `-1` when the
/// server did not send `Content-Length`.
class _DownloadProgress {
  _DownloadProgress(this.label, this.total)
      : _stopwatch = Stopwatch()..start(),
        _isTty = stdout.hasTerminal;

  final String label;
  final int total;
  final Stopwatch _stopwatch;
  final bool _isTty;

  int _received = 0;
  int _lastRenderMs = 0;
  int _lastLoggedPercent = -1;
  bool _done = false;

  void add(int bytes) {
    _received += bytes;
    final elapsedMs = _stopwatch.elapsedMilliseconds;
    if (_isTty) {
      // Throttle TTY redraws to ~10 Hz.
      if (elapsedMs - _lastRenderMs < 100) return;
      _lastRenderMs = elapsedMs;
      _render(elapsedMs);
    } else if (total > 0) {
      // Non-TTY: log a fresh line every ~10% so piped logs stay readable.
      final percent = (_received * 100 ~/ total).clamp(0, 100);
      if (percent >= _lastLoggedPercent + 10) {
        _lastLoggedPercent = percent - (percent % 10);
        logInfo(
          '  $label: $percent% (${_fmtBytes(_received)}'
          ' / ${_fmtBytes(total)})',
        );
      }
    }
  }

  void finish() {
    if (_done) return;
    _done = true;
    _stopwatch.stop();
    if (_isTty) {
      _render(_stopwatch.elapsedMilliseconds);
      stdout.writeln();
    } else {
      logInfo('  $label: done (${_fmtBytes(_received)})');
    }
  }

  void _render(int elapsedMs) {
    final rate = elapsedMs > 0 ? _received * 1000 / elapsedMs : 0.0;
    final buf = StringBuffer('  $label: ${_fmtBytes(_received)}');
    if (total > 0) {
      final percent =
          (_received * 100 / total).clamp(0, 100).toStringAsFixed(1);
      buf.write(' / ${_fmtBytes(total)} ($percent%)');
    }
    buf.write(' @ ${_fmtBytes(rate.round())}/s');
    // `\r` + right-pad so leftover chars from a longer prior line are erased.
    stdout.write('\r${buf.toString().padRight(78)}');
  }

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = n / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
  }
}

/// Drop the first [n] POSIX path segments from [name]; null if too few.
String? _strip(String name, int n) {
  if (n <= 0) return name;
  final parts = p.posix.split(name.replaceAll(r'\', '/'));
  if (parts.length <= n) return null;
  return p.posix.joinAll(parts.sublist(n));
}
