import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:xcross/src/cli/basic/sdk_install.dart';
import 'package:xcross/src/errors.dart';

export 'package:xcross/src/cli/basic/sdk_install.dart';

/// `xcross sdk` — manage xcross's host-neutral Darwin Swift SDK.
final class SdkCommand extends Command<void> {
  SdkCommand() {
    addSubcommand(SdkInstallCommand());
  }

  @override
  String get name => 'sdk';

  @override
  String get description => 'Manage the xcross Darwin Swift SDK.';
}

/// `xcross sdk install <Xcode.xip>` — build xcross's Darwin Swift SDK bundle.
final class SdkInstallCommand extends Command<void> {
  @override
  String get name => 'install';

  @override
  String get description =>
      'Extract a host-neutral Darwin Swift SDK from an Xcode.xip.';

  @override
  String get invocation => 'xcross sdk install <path-to-Xcode.xip>';

  @override
  Future<void> run() async {
    final xipPath = argResults!.rest.firstOrNull;
    if (xipPath == null) throw XcrossError('Usage: $invocation');
    if (!File(xipPath).existsSync()) {
      throw XcrossError('No file found at "$xipPath".');
    }

    final destDir = DarwinSdk.nativeInstallDir();
    final previous = Directory(SdkInstall.ioPath(destDir));
    if (previous.existsSync()) {
      await Log.logStep(
        'Removing previous SDK',
        () => previous.delete(recursive: true),
      );
    }

    final written = await _extract(xipPath, destDir);
    if (written == 0) {
      throw XcrossError(
        '$xipPath: extraction produced no files from the required iOS SDK '
        'subset. Verify that this is a complete Xcode.xip.',
      );
    }

    await Log.logStep(
      'Patching clang builtin headers',
      () => SdkInstall.replaceClangBuiltinHeaders(destDir),
    );
    await Log.logStep(
      'Copying Swift compatibility resources',
      () => SdkInstall.materializeSwiftCompatibilityResources(destDir),
    );
    await Log.logStep(
      'Writing Swift SDK metadata',
      () => SdkInstall.writeSwiftSdkBundleMetadata(destDir),
    );
    Log.logDone(
      'Installed Darwin Swift SDK '
      '(${ProgressBar.formatCount(written)} entries) at $destDir',
    );
  }

  /// Percentages track the compressed `Content` stream, the only size the
  /// archive declares up front; the entry and symlink counts ride along as the
  /// bar's trailing note so a stalled phase is still visibly doing work.
  Future<int> _extract(String xipPath, String destDir) async {
    final bar = ProgressBar('Extracting Darwin SDK');
    try {
      final written = await SdkInstall.writeSdkEntries(
        XcodeXipExtractor.extract(
          xipPath,
          onProgress: (consumed, total) {
            bar.total = total;
            bar.update(consumed);
          },
        ),
        destDir,
        onProgress: (count) =>
            bar.note = '${ProgressBar.formatCount(count)} entries',
        onLinkProgress: (done, total) => bar.note = 'linking $done/$total',
      );
      bar.finish('${ProgressBar.formatCount(written)} entries');
      return written;
    } on Object {
      bar.fail();
      rethrow;
    }
  }
}
