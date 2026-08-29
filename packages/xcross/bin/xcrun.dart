import 'dart:io';

import 'package:darwin_sdk_kit/darwin_sdk_kit.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  if (Platform.isMacOS) {
    stderr.writeln('xcross xcrun is only intended for Windows and Linux.');
    exitCode = 1;
    return;
  }

  try {
    exitCode = await runXcrun(arguments);
  } on Object catch (error) {
    stderr.writeln('xcrun: $error');
    exitCode = 1;
  }
}

Future<int> runXcrun(List<String> arguments) async {
  final sdk = DarwinSdk.current();
  if (sdk == null) {
    stderr.writeln(
      'xcrun: no Darwin SDK installed; run `xcross sdk install` first',
    );
    return 1;
  }

  if (arguments.contains('--show-sdk-path')) {
    stdout.writeln(sdk.iPhoneOSSdk());
    return 0;
  }

  final find = arguments.indexOf('--find');
  if (find >= 0) {
    if (find + 1 >= arguments.length) return 1;
    final tool = await _resolveTool(sdk, arguments[find + 1]);
    if (tool == null) return 1;
    stdout.writeln(tool);
    return 0;
  }

  final toolIndex = _toolIndex(arguments);
  if (toolIndex == -1) return 1;
  final tool = await _resolveTool(sdk, arguments[toolIndex]);
  if (tool == null) {
    stderr.writeln('xcrun: unknown tool ${arguments[toolIndex]}');
    return 1;
  }
  final process = await Process.start(
    tool,
    arguments.sublist(toolIndex + 1),
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

int _toolIndex(List<String> arguments) {
  for (var index = 0; index < arguments.length; index++) {
    if (arguments[index] == '--sdk') {
      index++;
      continue;
    }
    if (!arguments[index].startsWith('-')) return index;
  }
  return -1;
}

Future<String?> _findOnPath(String name) async {
  final executable = Platform.isWindows ? 'where' : 'which';
  final result = await Process.run(executable, [name]);
  if (result.exitCode != 0) return null;
  final first = result.stdout.toString().split(RegExp(r'[\r\n]+')).first.trim();
  return first.isEmpty ? null : first;
}

Future<String?> _resolveTool(DarwinSdk sdk, String name) async {
  final pathTool = await _findOnPath(name);
  if (pathTool != null &&
      p.canonicalize(pathTool) != p.canonicalize(Platform.resolvedExecutable)) {
    return pathTool;
  }
  switch (name) {
    case 'clang':
    case 'clang++':
      return DarwinSdk.resolveDarwinClang(sdk, name: name);
    case 'ld':
      return DarwinSdk.resolveLd64Lld(sdk);
    case 'ar':
      final clang = await DarwinSdk.resolveDarwinClang(sdk);
      final sibling = p.join(
        p.dirname(clang),
        'llvm-ar${Platform.isWindows ? '.exe' : ''}',
      );
      if (File(sibling).existsSync()) return sibling;
      return DarwinSdk.locateLlvmTool(
        Platform.isWindows ? 'llvm-ar.exe' : 'llvm-ar',
      );
    case 'lipo':
      return DarwinSdk.locateLlvmTool(
        Platform.isWindows ? 'llvm-lipo.exe' : 'llvm-lipo',
      );
    case 'otool':
      return await DarwinSdk.locateLlvmTool(
            Platform.isWindows ? 'llvm-otool.exe' : 'llvm-otool',
          ) ??
          DarwinSdk.locateLlvmTool(
            Platform.isWindows ? 'llvm-objdump.exe' : 'llvm-objdump',
          );
    case 'install_name_tool':
      return DarwinSdk.locateLlvmTool(
        Platform.isWindows
            ? 'llvm-install-name-tool.exe'
            : 'llvm-install-name-tool',
      );
    case 'codesign':
      return null;
    default:
      return DarwinSdk.locateLlvmTool(Platform.isWindows ? '$name.exe' : name);
  }
}
