import 'dart:convert';
import 'dart:io';

import 'package:xcross/src/util/errors.dart';
import 'package:xcross/src/util/logging.dart';

/// Captured result of a finished subprocess.
class CapturedProcess {
  CapturedProcess(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;
}

/// Matches shell special characters that require quoting.
final _shellSpecialCharsPattern = RegExp(r'''[\s'"\\$`]''');

/// Thin wrappers around `dart:io` [Process] with consistent UTF-8 decoding and
/// error reporting.
abstract final class ProcessRunner {
  /// Run [executable] to completion, capturing stdout/stderr as UTF-8 strings.
  static Future<CapturedProcess> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    return CapturedProcess(
      result.exitCode,
      result.stdout as String,
      result.stderr as String,
    );
  }

  /// Run [executable], throwing [XcrossError] on a non-zero exit code.
  ///
  /// When [inheritStdio] is true the child shares this process's stdio via
  /// [ProcessStartMode.inheritStdio] (needed for interactive prompts like
  /// `xtool install` certificate revocation). Otherwise output is captured
  /// and the stderr is included in the thrown error.
  static Future<void> runChecked(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool inheritStdio = false,
    String? label,
  }) async {
    final prefix = label ?? _labelForExecutable(executable);
    logStatus('[$prefix] running: ${commandLine(executable, arguments)}');

    if (inheritStdio) {
      // Must use inheritStdio (not piped stdout/stderr): xtool writes
      // confirmation prompts without a trailing newline and reads stdin.
      // Piping + LineSplitter hid the prompt and left stdin disconnected,
      // so install hung at "certificates must be revoked".
      final process = await Process.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        mode: ProcessStartMode.inheritStdio,
      );
      final code = await process.exitCode;
      if (code != 0) {
        throw XcrossError(
            'command failed ($code): ${commandLine(executable, arguments)}');
      }
      return;
    }

    final result = await run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
    );
    if (result.exitCode != 0) {
      throw XcrossError(
        'command failed (${result.exitCode}): '
        '${commandLine(executable, arguments)}\n${result.stderr}',
      );
    }
  }

  static String _labelForExecutable(String executable) {
    final normalized = executable.replaceAll(String.fromCharCode(92), '/');
    final base = normalized.split('/').last;
    if (base.isEmpty) return executable;
    return base;
  }

  /// Shell-like command rendering for logs and errors.
  static String commandLine(String executable, List<String> arguments) =>
      [executable, ...arguments].map(_shellQuote).join(' ');

  static String _shellQuote(String s) {
    if (s.isEmpty) return "''";
    if (!_shellSpecialCharsPattern.hasMatch(s)) return s;
    return "'${s.replaceAll("'", r"'\''")}'";
  }

}
