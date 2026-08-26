import 'dart:io';

import 'package:cli_kit/cli_kit.dart';
import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:xcross/src/flutter/build/internal/apple_tool_shim_templates.dart';
import 'package:xcross/src/flutter/errors.dart';

@immutable
final class OtoolConfig {
  const OtoolConfig(this.executable, {required this.usesObjdump});

  final String executable;
  final bool usesObjdump;
}

@immutable
final class AppleToolShimConfig {
  const AppleToolShimConfig({
    required this.iosSdk,
    required this.clang,
    required this.hostCompiler,
    required this.archiver,
    required this.linker,
    required this.lipo,
    required this.otool,
    required this.installNameTool,
    required this.deploymentTarget,
  });

  final String iosSdk;
  final String clang;
  final String hostCompiler;
  final String archiver;
  final String linker;
  final String lipo;
  final OtoolConfig? otool;
  final String? installNameTool;
  final String deploymentTarget;

  static Future<AppleToolShimConfig> resolve(String deploymentTarget) async {
    final sdk = DarwinSdk.current();
    if (sdk == null) {
      throw FlutterBuildError(
        'Native assets require an installed Darwin SDK. Run '
        '`xcross sdk install <Xcode.xip|Xcode.app>` first.',
      );
    }
    final clang = await DarwinSdk.resolveDarwinClang(sdk);
    return AppleToolShimConfig(
      iosSdk: sdk.iPhoneOSSdk(),
      clang: clang,
      hostCompiler: await resolveHostCompiler(clang),
      archiver: await _locateArchiver(clang),
      linker: await DarwinSdk.resolveLd64Lld(sdk),
      lipo: await locateLlvmTool('llvm-lipo'),
      otool: await resolveOtool(),
      installNameTool: await findLlvmTool('llvm-install-name-tool'),
      deploymentTarget: deploymentTarget,
    );
  }
}

Future<String> resolveHostCompiler(String clang, {bool? windows}) async =>
    (windows ?? Platform.isWindows) ? clang : ProcessRunner.locateTool('cc');

Future<String> _locateArchiver(String clang) async {
  final besideClang = p.join(
    p.dirname(clang),
    'llvm-ar${Platform.isWindows ? '.exe' : ''}',
  );
  if (File(besideClang).existsSync()) return besideClang;
  return locateLlvmTool('llvm-ar');
}

Future<String?> findLlvmTool(String name) =>
    DarwinSdk.locateLlvmTool(ProcessRunner.hostExecutableName(name));

Future<OtoolConfig?> resolveOtool({
  Future<String?> Function(String name) find = findLlvmTool,
}) async {
  final otool = await find('llvm-otool');
  if (otool != null) return OtoolConfig(otool, usesObjdump: false);
  final objdump = await find('llvm-objdump');
  return objdump == null ? null : OtoolConfig(objdump, usesObjdump: true);
}

Future<String> locateLlvmTool(String name) async {
  final tool = await findLlvmTool(name);
  if (tool != null) return tool;
  throw FlutterBuildError("Could not find '$name'. Install LLVM and retry.");
}

/// Installs the Apple command-line surface needed by Flutter build hooks.
Future<void> installAppleToolShims(
  String directory,
  AppleToolShimConfig config, {
  String? launcherExecutable,
}) async {
  await Directory(directory).create(recursive: true);
  final compilerShim = p.join(
    directory,
    Platform.isWindows ? 'clang.bat' : 'clang',
  );
  final otoolShim = p.join(
    directory,
    Platform.isWindows ? 'otool.bat' : 'otool',
  );
  final tools = <String, String>{
    'clang': compilerShim,
    'ar': config.archiver,
    'ld': config.linker,
    'lipo': config.lipo,
    if (config.otool != null) 'otool': otoolShim,
    if (config.installNameTool case final tool?) 'install_name_tool': tool,
  };

  if (Platform.isWindows) {
    if (launcherExecutable != null) {
      final source = p.join(directory, 'xcrun.dart');
      await File(source).writeAsString(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final executable = Platform.resolvedExecutable;
  final directory = File(executable).parent.path;
  final name = executable.split(Platform.pathSeparator).last.split('.').first;
  if (name != 'xcrun') {
    final target = File('$directory\\$name.path').readAsStringSync();
    final process = await Process.start(
      target,
      arguments,
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
    return;
  }
  if (arguments.contains('--show-sdk-path')) {
    stdout.writeln(File('$executable.sdk').readAsStringSync());
    return;
  }
  final toolIndex = arguments.indexWhere(
    (argument) => !argument.startsWith('-') && File('$directory\\$argument.bat').existsSync(),
  );
  if (toolIndex >= 0) {
    final process = await Process.start(
      '$directory\\${arguments[toolIndex]}.bat',
      arguments.sublist(toolIndex + 1),
      mode: ProcessStartMode.inheritStdio,
      runInShell: true,
    );
    exitCode = await process.exitCode;
    return;
  }
  final find = arguments.indexOf('--find');
  if (find >= 0 && find + 1 < arguments.length) {
    final tool = arguments[find + 1];
    final shim = '$directory\\$tool.bat';
    if (File(shim).existsSync()) {
      stdout.writeln(shim);
      return;
    }
    final mapping = File('$directory\\$tool.path');
    if (mapping.existsSync()) {
      stdout.writeln(mapping.readAsStringSync());
      return;
    }

  }
  stderr.writeln('error: unsupported xcrun invocation: ${arguments.join(' ')}');
  exitCode = 1;
}
''');
      await ProcessRunner.runChecked(launcherExecutable, [
        'compile',
        'exe',
        source,
        '-o',
        p.join(directory, 'xcrun.exe'),
      ], label: 'xcrun shim');
      if (!File(p.join(directory, 'xcrun.exe')).existsSync()) {
        throw FlutterBuildError('Failed to create the xcrun executable shim.');
      }
      await File(
        p.join(directory, 'xcrun.exe.sdk'),
      ).writeAsString(config.iosSdk);
      for (final entry in {
        'ar': config.archiver,
        'ld': config.linker,
        'cc': compilerShim,
      }.entries) {
        await File(
          p.join(directory, '${entry.key}.path'),
        ).writeAsString(entry.value);
        await File(
          p.join(directory, 'xcrun.exe'),
        ).copy(p.join(directory, '${entry.key}.exe'));
      }
    }

    if (config.otool case final otool?) {
      await File(p.join(directory, 'otool.ps1')).writeAsString(
        renderPowerShellOtoolShim(
          tool: otool.executable,
          usesObjdump: otool.usesObjdump,
        ),
      );
      await _writeWindowsShim(
        directory,
        'otool',
        renderBatchPowerShellShim('otool.ps1'),
      );
    }
    await File(p.join(directory, 'clang.ps1')).writeAsString(
      renderPowerShellCompilerShim(
        iosSdk: config.iosSdk,
        clang: config.clang,
        hostCompiler: config.hostCompiler,
        linker: config.linker,
        deploymentTarget: config.deploymentTarget,
      ),
    );
    await _writeWindowsShim(
      directory,
      'clang',
      renderBatchPowerShellShim('clang.ps1'),
    );
    if (launcherExecutable == null) {
      await _writeWindowsShim(
        directory,
        'cc',
        renderBatchPowerShellShim('clang.ps1'),
      );
      await _writeWindowsShim(
        directory,
        'ar',
        renderBatchToolShim(config.archiver),
      );
      await _writeWindowsShim(
        directory,
        'ld',
        renderBatchToolShim(config.linker),
      );
    }
    if (launcherExecutable == null) {
      await File(p.join(directory, 'xcrun.ps1')).writeAsString(
        renderPowerShellXcrunShim(iosSdk: config.iosSdk, tools: tools),
      );
      await _writeWindowsShim(
        directory,
        'xcrun',
        renderBatchPowerShellShim('xcrun.ps1'),
      );
    }
    for (final tool in tools.entries.skip(3)) {
      if (tool.key != 'otool') {
        await _writeWindowsShim(
          directory,
          tool.key,
          renderBatchToolShim(tool.value),
        );
      }
    }
    if (config.installNameTool == null) {
      await _writeWindowsShim(
        directory,
        'install_name_tool',
        batchCodesignShim,
      );
    }
    await _writeWindowsShim(directory, 'codesign', batchCodesignShim);
    await File(p.join(directory, 'rsync.ps1')).writeAsString(r'''
$items = @($args | Where-Object { -not $_.StartsWith('-') -and $_ -ne '.DS_Store/' })
if ($items.Count -lt 2) { exit 1 }
$source = $items[$items.Count - 2]
$destination = $items[$items.Count - 1]
Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
exit 0
''');
    await _writeWindowsShim(
      directory,
      'rsync',
      renderBatchPowerShellShim('rsync.ps1'),
    );
    return;
  }

  if (config.otool case final otool?) {
    await _writeUnixShim(
      directory,
      'otool',
      renderUnixOtoolShim(
        tool: otool.executable,
        usesObjdump: otool.usesObjdump,
      ),
    );
  }
  final compilerScript = renderUnixCompilerShim(
    iosSdk: config.iosSdk,
    clang: config.clang,
    hostCompiler: config.hostCompiler,
    linker: config.linker,
    deploymentTarget: config.deploymentTarget,
  );
  await _writeUnixShim(directory, 'clang', compilerScript);
  await _writeUnixShim(directory, 'cc', compilerScript);
  await _writeUnixShim(
    directory,
    'xcrun',
    renderUnixXcrunShim(iosSdk: config.iosSdk, tools: tools),
  );
  for (final tool in tools.entries.skip(3)) {
    if (tool.key != 'otool') {
      await _writeUnixShim(directory, tool.key, renderUnixToolShim(tool.value));
    }
  }
  await _writeUnixShim(directory, 'codesign', unixCodesignShim);
}

Future<void> _writeUnixShim(
  String directory,
  String name,
  String contents,
) async {
  final file = File(p.join(directory, name));
  await file.writeAsString(contents);
  ProcessRunner.makeExecutable(file.path);
}

Future<void> _writeWindowsShim(
  String directory,
  String name,
  String contents,
) => File(p.join(directory, '$name.bat')).writeAsString(contents);
