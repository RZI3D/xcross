import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:xcross/src/constants/device_constants.dart';
import 'package:xcross/src/device/dart_vm_service_client.dart';
import 'package:xcross/src/models/device/hot_reload_config.dart';
import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Drives Flutter hot reload / hot restart by:
///   1. Spawning a persistent `frontend_server` for incremental kernel diffs.
///   2. Uploading those diffs into the app's devFS over HTTP.
///   3. Calling `reloadSources` / `_flutter.runInView` on the Dart VM Service.
///
/// HotReloadController.swift:12
class HotReloadController {
  static final _whitespacePattern = RegExp(r'\s+');

  /// Fallback devFS base URI used when `_createDevFs` does not return one.
  static const _devFsFallbackUri =
      'org-dartlang-devfs://${DeviceConstants.devFsName}/';

  HotReloadController({
    required this.config,
    required this.vm,
    required this.tunnelAddress,
    required int vmServicePort,
  }) : _httpBase = 'http://${_bracket(tunnelAddress)}:$vmServicePort/';

  final HotReloadConfig config;
  final DartVmServiceClient vm;
  final String tunnelAddress;
  final String _httpBase;

  Process? _frontendProcess;
  IOSink? _fsSink;

  // Persistent pull-based reader — fixes single-subscription re-listen bug.
  // Bug: returning early from `await for` cancels the subscription; the second
  // call to _readResultBoundary would throw StateError. StreamQueue allows
  // repeated `hasNext`/`next` calls across multiple compile rounds.
  StreamQueue<String>? _fsQueue;

  String? _devFsBaseUri;

  /// Incremented per hot restart to alternate the devFS dill filename.
  int _restartCount = 0;

  /// Content hash of each `lib/` `.dart` file at the last compile — the baseline
  /// for change detection.
  final Map<String, int> _libHashes = {};

  /// Cached root Flutter isolate id so reload doesn't re-`listViews` each time.
  /// Cleared on hot restart (which spins up a new isolate).
  String? _cachedRootIsolate;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Initial compile + devFS creation. Call once after VM Service connects.
  /// HotReloadController.swift:63
  Future<void> initialSync() async {
    await _spawnFrontendServer();
    await _createDevFs();
    await _compileInitialBaseline();
  }

  Future<void> _compileInitialBaseline() async {
    // App already runs its bundled kernel. We only prime frontend_server's
    // incremental state here; uploading the full seed dill makes first reload
    // wait behind a multi-MB devFS transfer.
    await _compile();
    await _acceptFrontendOutput();
    _snapshotLib();
  }

  /// Time [body] and log `[timing] <label> <ms>ms` (helps locate reload cost).
  Future<T> _timed<T>(String label, Future<T> Function() body) async {
    if (!config.verbose) return body();
    final sw = Stopwatch()..start();
    try {
      return await body();
    } finally {
      logStatus('[timing] $label ${sw.elapsedMilliseconds}ms');
    }
  }

  /// Stop the frontend_server process. HotReloadController.swift:71
  Future<void> close() async {
    // Flush `quit` before killing so the process can exit cleanly.
    // Fix: await flush ensures the write is delivered before kill().
    await _sendFrontend('quit\n');
    _frontendProcess?.kill();
    _frontendProcess = null;
    await _fsSink?.close();
    _fsSink = null;
    await _fsQueue?.cancel(immediate: true);
    _fsQueue = null;
    // Close the VM Service WebSocket so its socket/timers don't keep the event
    // loop alive after the session ends.
    await vm.close();
  }

  // ── User-facing ops ───────────────────────────────────────────────────────

  /// Recompile changed sources, push delta, reload the ROOT Flutter isolate.
  ///
  /// Only the root isolate is reloaded (via `_flutter.listViews`), like
  /// flutter_tools — reloading every isolate from `getVM` can hit a worker
  /// isolate that rejects, which discarded the whole (good) delta and forced a
  /// redo. HotReloadController.swift:83
  Future<bool> reload() async {
    final changed = _changedLibFileUris();
    if (changed.isEmpty) {
      logStatus('[xtool] no source changes');
      return true;
    }

    final dill =
        await _timed('recompile', () => _recompile(invalidated: changed));
    final targetUri = await _timed('devfs-upload', () => _uploadDill(dill));

    final isolateId = await _rootIsolateIdCached();
    if (isolateId == null) throw XcrossError('no Flutter isolate to reload');

    final ok = await _timed('reloadSources', () async {
      final report = await vm.call('reloadSources', params: {
        'isolateId': isolateId,
        'force': false,
        'rootLibUri': targetUri,
      });
      return report['success'] == true;
    });
    if (ok) {
      await _acceptFrontendOutput();
      await _timed('reassemble', () async {
        try {
          await vm
              .call('ext.flutter.reassemble', params: {'isolateId': isolateId});
        } catch (_) {}
      });
    } else {
      await _sendFrontend('reject\n');
    }
    return ok;
  }

  /// Full restart: recompile, push (to an alternating swap dill), then
  /// `_flutter.runInView` on each view and await the isolate becoming runnable
  /// (rather than the RPC's own return, which on-device can exceed the default
  /// timeout). HotReloadController.swift:122
  Future<void> restart() async {
    // Force a full recompile if nothing changed, so runInView gets a dill.
    var changed = _changedLibFileUris();
    if (changed.isEmpty) {
      changed = [for (final p in _libDartFiles()) Uri.file(p).toString()];
    }
    _cachedRootIsolate = null; // a new isolate comes up after runInView
    final dill = await _recompile(invalidated: changed);
    // Alternate the devFS file name so runInView always loads a fresh URI.
    _restartCount++;
    final fileName =
        _restartCount.isEven ? 'main.dart.dill' : 'main.dart.swap.dill';
    final targetUri = await _uploadDill(dill, fileName: fileName);
    await _acceptFrontendOutput();

    await vm.streamListen('Isolate');
    final viewIds = await _flutterViewIds();
    final assetDir = '${_devFsBaseUri ?? _devFsFallbackUri}flutter_assets/';
    const longTimeout = Duration(minutes: 2);
    for (final viewId in viewIds) {
      final runnable = vm.waitForEvent('IsolateRunnable', timeout: longTimeout);
      await vm.call(
        '_flutter.runInView',
        params: {
          'viewId': viewId,
          'mainScript': targetUri,
          'assetDirectory': assetDir,
        },
        timeout: longTimeout,
      );
      await runnable;
    }
  }

  // ── Reload helpers ────────────────────────────────────────────────────────

  /// Cached root isolate id (avoids a `_flutter.listViews` round-trip per reload).
  Future<String?> _rootIsolateIdCached() async =>
      _cachedRootIsolate ??= await _rootIsolateId();

  /// The root Flutter isolate id (first view's isolate) via `_flutter.listViews`.
  Future<String?> _rootIsolateId() async {
    for (final view in await _flutterViews()) {
      // Map pattern: match nested {'isolate': {'id': <String>}} in one step.
      if (view case {'isolate': {'id': final String id}}) return id;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _flutterViews() async {
    final viewData = await vm.call('_flutter.listViews');
    final viewArray = viewData['views'] as List<dynamic>? ?? [];
    return viewArray.whereType<Map<String, dynamic>>().toList();
  }

  /// Return the list of Flutter view IDs from `_flutter.listViews`.
  Future<List<String>> _flutterViewIds() async => [
        for (final v in await _flutterViews())
          if (v case {'id': final String id}) id,
      ];

  // ── devFS ─────────────────────────────────────────────────────────────────

  /// HotReloadController.swift:145
  Future<void> _createDevFs() async {
    Future<Map<String, dynamic>> tryCreate() =>
        vm.call('_createDevFS', params: {'fsName': DeviceConstants.devFsName});

    Map<String, dynamic> data;
    try {
      data = await tryCreate();
    } catch (e) {
      if (e.toString().contains('already exists')) {
        try {
          await vm.call('_deleteDevFS',
              params: {'fsName': DeviceConstants.devFsName});
        } catch (_) {}
        data = await tryCreate();
      } else {
        rethrow;
      }
    }
    _devFsBaseUri = data['uri'] as String? ?? _devFsFallbackUri;
  }

  /// PUT [dillPath] (gzipped) into devFS as [fileName].
  /// Returns the devFS URI of the uploaded file. HotReloadController.swift:163
  Future<String> _uploadDill(String dillPath,
      {String fileName = 'main.dart.dill'}) async {
    final baseUri = _devFsBaseUri ?? _devFsFallbackUri;
    final targetUri = '$baseUri$fileName';
    final raw = await File(dillPath).readAsBytes();
    final gz = GZipCodec().encode(raw);
    if (config.verbose) {
      logStatus('[timing] devfs-bytes raw=${raw.length} gz=${gz.length}');
    }
    final targetUriB64 = base64.encode(utf8.encode(targetUri));

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.putUrl(Uri.parse(_httpBase));
      req.headers.set('dev_fs_name', DeviceConstants.devFsName);
      req.headers.set('dev_fs_uri_b64', targetUriB64);
      req.headers.contentType = ContentType('application', 'octet-stream');
      req.contentLength = gz.length;
      req.add(gz);
      final resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw XcrossError('devFS upload failed: HTTP ${resp.statusCode}');
      }
    } catch (e) {
      if (e is XcrossError) rethrow;
      throw XcrossError('devFS upload failed: $e');
    } finally {
      client.close();
    }
    return targetUri;
  }

  // ── frontend_server ───────────────────────────────────────────────────────

  /// Kernel dill the debug build already produced (FlutterDebugBundler). Used to
  /// warm-start the incremental compiler via `--initialize-from-dill`.
  String get _buildKernelDill =>
      '${config.projectRoot}/build/xtool-flutter-debug/.kernel/app.dill';

  /// HotReloadController.swift:197
  Future<void> _spawnFrontendServer() async {
    final isAot = config.frontendServer.contains('_aot');
    final buildKernelDillExists = File(_buildKernelDill).existsSync();
    final args = <String>[
      if (!isAot) '--disable-dart-dev',
      config.frontendServer,
      '--sdk-root',
      if (config.sdkRoot.endsWith('/'))
        config.sdkRoot
      else
        '${config.sdkRoot}/',
      '--incremental',
      '--target=flutter',
      '--no-print-incremental-dependencies',
      '-Ddart.developer.serviceExtensionStream.enabled=true',
      '-Ddart.vm.profile=false',
      '-Ddart.vm.product=false',
      '--track-widget-creation',
      // User-supplied --dart-define=KEY=VALUE entries. HotReloadController.swift:202
      for (final d in config.dartDefines) '-D$d',
      // Warm-start the incremental compiler from the kernel the build already
      // produced, so the initial compile is a fast delta instead of a cold full
      // compile — cuts the wait before "hot reload ready".
      if (buildKernelDillExists) ...[
        '--initialize-from-dill',
        _buildKernelDill,
      ],
      '--packages',
      config.packageConfig,
      '--output-dill',
      config.outputDill,
    ];

    // Ensure output directory exists. HotReloadController.swift:215
    await Directory(File(config.outputDill).parent.path)
        .create(recursive: true);

    logStatus('[frontend_server] running: ${config.dart} ${args.join(' ')}');
    final proc = await Process.start(
      config.dart,
      args,
      // Forward stderr so we see compile errors. HotReloadController.swift:227
    );

    _frontendProcess = proc;
    _fsSink = proc.stdin;
    // Wrap stdout in a StreamQueue so _readResultBoundary can pull lines
    // across multiple compile rounds without re-subscribing.
    // Fix: single-subscription stream re-listen bug — StreamQueue holds the
    // subscription internally and exposes hasNext/next pull API.
    // HotReloadController.swift:237
    _fsQueue = StreamQueue<String>(
      proc.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    // Forward compile errors to our stderr with a program prefix.
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => stderr.writeln('[frontend_server] $line'));
  }

  // HotReloadController.swift:240
  Future<String> _compile() async {
    final entrypointUri = Uri.file(config.entrypoint).toString();
    await _sendFrontend('compile $entrypointUri\n');
    return _readResultBoundary();
  }

  // HotReloadController.swift:245
  Future<String> _recompile({required List<String> invalidated}) async {
    final entrypointUri = Uri.file(config.entrypoint).toString();
    // Hex-encoded microsecond timestamp used as the boundary token that wraps
    // the invalidated-file list in the frontend_server recompile protocol.
    final boundaryToken =
        DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    final sb = StringBuffer()
      ..write('recompile $entrypointUri $boundaryToken\n');
    for (final uri in invalidated) {
      sb.write('$uri\n');
    }
    sb.write('$boundaryToken\n');
    await _sendFrontend(sb.toString());
    return _readResultBoundary();
  }

  /// Write [s] to frontend_server stdin and flush. Async so callers can
  /// await delivery — fixes bug where accept/reject/quit could be dropped if
  /// the process was killed before the OS buffer was flushed.
  /// HotReloadController.swift:254-261
  Future<void> _sendFrontend(String s) async {
    final sink = _fsSink;
    if (sink == null) throw XcrossError('frontend_server closed unexpectedly');
    sink.write(s);
    await sink.flush();
  }

  /// Commit the latest frontend_server output as the next incremental baseline.
  Future<void> _acceptFrontendOutput() => _sendFrontend('accept\n');

  /// Parse `result <boundary>\n...\n<boundary> <dill> <errCount>` from stdout.
  /// Returns the local dill file path. HotReloadController.swift:265
  ///
  /// Uses [_fsQueue] (StreamQueue) so the subscription is held persistently
  /// across calls — fixes the single-subscription re-listen bug where returning
  /// from `await for` cancelled the subscription on every compile round.
  Future<String> _readResultBoundary() {
    final queue = _fsQueue;
    if (queue == null) throw XcrossError('frontend_server closed unexpectedly');
    // Never block forever: if frontend_server emits no result, fail instead.
    return _parseResultBoundary(queue).timeout(
      const Duration(seconds: 60),
      onTimeout: () =>
          throw XcrossError('frontend_server: no result within 60s'),
    );
  }

  Future<String> _parseResultBoundary(StreamQueue<String> queue) async {
    String? boundary;
    while (await queue.hasNext) {
      final line = await queue.next;
      if (boundary == null) {
        if (line.startsWith('result ')) {
          boundary = line.substring('result '.length).trim();
        }
        continue;
      }
      if (line.startsWith(boundary)) {
        // frontend_server prints the boundary token alone first, then again as
        // "<boundary> <dill> <errcount>". Skip the bare echo and keep reading
        // until the line that carries the dill path.
        final rest = line.substring(boundary.length).trim();
        if (rest.isEmpty) continue;
        final parts = rest.split(_whitespacePattern);
        // Trailing token is the error count; everything before it is the path.
        // List pattern: [...pathTokens, _] captures all-but-last into pathTokens.
        final dill = switch (parts) {
          [...final pathTokens, _] when pathTokens.isNotEmpty =>
            pathTokens.join(' '),
          _ => rest,
        };
        if (dill.isEmpty) continue;
        return dill;
      }
    }
    throw XcrossError('frontend_server closed unexpectedly');
  }

  // ── Changed file discovery ────────────────────────────────────────────────

  /// `lib/` `.dart` files modified after the session started, as `file://` URIs,
  /// passed to frontend_server's `recompile` as the invalidated set.
  ///
  /// Only files edited *during* the session are recompiled — so a reload does
  /// the minimum work (fast) rather than recompiling all of `lib/`. Scope is
  /// `lib/` on purpose: `test/`/`bin/`/`tool/` import non-runtime deps (e.g.
  /// `flutter_test`) that would balloon the compile.
  ///
  /// Baseline is the fixed [_sessionStart] (not the previous compile time), so
  /// every edit made since launch is caught even if the virtiofs mount reports
  /// mtimes a little late.
  ///
  /// Pruned manual walk so `.fvm`/`.dart_tool`/`build`/`.git` aren't traversed.
  /// HotReloadController.swift:306
  List<String> _libDartFiles() {
    var root = Directory('${config.projectRoot}/lib');
    final libDirExists = root.existsSync();
    if (!libDirExists) root = Directory(config.projectRoot);
    final projectRootExists = root.existsSync();
    if (!projectRootExists) return const [];
    final files = <String>[];
    final stack = <Directory>[root];
    while (stack.isNotEmpty) {
      final dir = stack.removeLast();
      final List<FileSystemEntity> entries;
      try {
        // listSync: cheap synchronous scan — avoids async overhead per dir.
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue;
      }
      for (final entity in entries) {
        final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (entity is Directory) {
          if (name.startsWith('.') || name == 'build') continue;
          stack.add(entity);
        } else if (entity is File && name.endsWith('.dart')) {
          files.add(entity.absolute.path);
        }
      }
    }
    return files;
  }

  // FNV-1a 64-bit: offset basis = 0xcbf29ce484222325, prime = 0x100000001b3.

  /// 64-bit FNV-1a hash of file bytes — cheap, collision-safe enough to detect
  /// edits by content (mtime is unreliable over the virtiofs mount).
  static int _fnv1a(List<int> bytes) {
    // Native (dart compile exe) 64-bit ints; JS rounding doesn't apply.
    // ignore: avoid_js_rounded_ints
    var hash = 0xcbf29ce484222325;
    for (final b in bytes) {
      hash = (hash ^ b) * 0x100000001b3;
    }
    return hash & 0x7fffffffffffffff;
  }

  /// Record the current content hash of every `lib/` `.dart` file, establishing
  /// the baseline for [_changedLibFileUris].
  void _snapshotLib() {
    _libHashes.clear();
    for (final path in _libDartFiles()) {
      try {
        _libHashes[path] = _fnv1a(File(path).readAsBytesSync());
      } catch (_) {}
    }
  }

  /// `lib/` `.dart` files whose *content* changed since the last snapshot, as
  /// `file://` URIs. Content-based so it reliably catches an edit on the first
  /// `r` regardless of mtime/clock behaviour, and returns empty when nothing
  /// actually changed (so we skip a pointless recompile). Updates the snapshot.
  List<String> _changedLibFileUris() {
    final changed = <String>[];
    for (final path in _libDartFiles()) {
      final int hash;
      try {
        hash = _fnv1a(File(path).readAsBytesSync());
      } catch (_) {
        continue;
      }
      if (_libHashes[path] != hash) {
        changed.add(Uri.file(path).toString());
        _libHashes[path] = hash;
      }
    }
    return changed;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Wrap IPv6 address in brackets for URL construction.
  static String _bracket(String addr) => addr.contains(':') ? '[$addr]' : addr;
}
