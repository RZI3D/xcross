import 'package:meta/meta.dart';

/// Options shared by `xcross flutter build` and `run`, mirroring the semantics
/// of the official `flutter build ios` / `flutter run` arguments. xcross accepts
/// a mix of these flutter-style flags and the original xtool flags.
///
/// xcross is debug-only, so there is no build-mode field.
@immutable
class FlutterBuildOptions {
  const FlutterBuildOptions({
    this.target = 'lib/main.dart',
    this.dartDefines = const [],
    this.pub = true,
    this.buildName,
    this.buildNumber,
    this.flavor,
  });

  /// `-t/--target` entrypoint (default `lib/main.dart`).
  final String target;

  /// Merged `--dart-define` + `--dart-define-from-file` values as `KEY=VALUE`
  /// strings (file entries first, explicit `--dart-define` overriding them).
  final List<String> dartDefines;

  /// `--[no-]pub` — whether to run `flutter pub get` (default true).
  final bool pub;

  /// `--build-name` → `CFBundleShortVersionString` (default 1.0.0 if null).
  final String? buildName;

  /// `--build-number` → `CFBundleVersion` (default 1 if null).
  final String? buildNumber;

  /// `--flavor` — sets the `FLUTTER_APP_FLAVOR` dart-define, readable at
  /// runtime via `appFlavor` from `package:flutter/services`.
  final String? flavor;
}
