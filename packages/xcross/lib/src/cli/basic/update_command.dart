import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:build_cli_annotations/build_cli_annotations.dart';
import 'package:cli_kit/cli_kit.dart';
import 'package:xcross/src/errors.dart';
import 'package:xcross/src/update/install_layout.dart';
import 'package:xcross/src/update/release_lookup.dart';
import 'package:xcross/src/update/self_update.dart';
import 'package:xcross/src/update/semver.dart';
import 'package:xcross/src/version.dart';

part 'update_command.g.dart';

/// Options for `xcross update`.
@CliOptions(createCommand: true)
final class UpdateArgs {
  @CliOption(
    negatable: false,
    help: 'Report the latest version without installing anything.',
  )
  late bool check;

  @CliOption(
    valueHelp: 'tag',
    help: 'Install a specific release tag instead of the latest.',
  )
  late String? to;

  @CliOption(
    negatable: false,
    help: 'Reinstall even when the running version is already current.',
  )
  late bool force;

  @CliOption(abbr: 'y', negatable: false, help: 'Skip the confirmation prompt.')
  late bool yes;
}

/// `xcross update` — replace the installed xcross with a published release.
///
/// The archive is verified against the release's `SHA256SUMS.txt` before any
/// file is touched.
final class UpdateCommand extends _$UpdateArgsCommand<void> {
  @override
  String get name => 'update';

  @override
  String get description =>
      'Update xcross to the latest published release, verifying the download '
      'against the release checksums.';

  @override
  Future<void> run() async {
    final args = _options;
    // A dev build has no release to compare against and no business
    // overwriting whatever bundle it happens to sit next to.
    if (XcrossVersion.isDev) {
      throw XcrossError(
        'this xcross was built from a source checkout '
        '(${XcrossVersion.current}); update only works on a binary installed '
        'by install.sh or install.ps1.',
      );
    }
    final layout = InstallLayout.resolve();
    // Fails fast on macOS or an unsupported CPU, before any network traffic.
    final asset = SelfUpdate.assetName();

    final tag = args.to ?? await _latestTag();
    final target = XcrossSemver.tryParse(tag);
    if (target == null) {
      throw XcrossError('release tag "$tag" is not a version xcross can read');
    }

    if (args.check) {
      _reportComparison(tag: tag, target: target);
      return;
    }

    if (!args.force && !_isUpgrade(target) && args.to == null) {
      Log.logDone('xcross ${XcrossVersion.current} is already the latest');
      return;
    }

    Log.logInfo('Release', '$tag (installed: ${XcrossVersion.current})');
    Log.logInfo('Asset', asset);
    if (!_confirm(tag: tag, skipPrompt: args.yes)) {
      Log.logStatus('Aborted.');
      return;
    }

    await SelfUpdate.apply(layout: layout, tag: tag);
    Log.logDone('Updated xcross to $tag', layout.binaryPath);
  }

  Future<String> _latestTag() =>
      Log.logStep('Checking for updates', ReleaseLookup.latestTag);

  void _reportComparison({required String tag, required XcrossSemver target}) {
    if (_isUpgrade(target)) {
      Log.logInfo(
        'xcross $tag is available (installed: ${XcrossVersion.current})',
      );
      Log.logStatus("Run 'xcross update' to install it.");
      return;
    }
    Log.logDone(
      'xcross $tag is the latest version '
      '(installed: ${XcrossVersion.current})',
    );
  }

  static bool _isUpgrade(XcrossSemver target) {
    final current = XcrossSemver.tryParse(XcrossVersion.current);
    return current == null || target.isNewerThan(current);
  }

  /// A non-interactive shell cannot answer, so it is treated as consent: the
  /// user explicitly ran `xcross update` to get exactly this.
  static bool _confirm({required String tag, required bool skipPrompt}) {
    if (skipPrompt || !stdin.hasTerminal) return true;
    stdout.write('Update xcross to $tag? [y/N] ');
    final answer = stdin.readLineSync()?.trim().toLowerCase();
    return answer == 'y' || answer == 'yes';
  }
}
