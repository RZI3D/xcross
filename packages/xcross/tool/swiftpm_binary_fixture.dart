import 'dart:io';

import 'package:xcross/src/flutter/build/internal/swiftpm_binary_fixture.dart';

void main(List<String> arguments) {
  if (arguments.length != 2) {
    stderr.writeln('usage: swiftpm_binary_fixture.dart <output> <archive-url>');
    exitCode = 64;
    return;
  }
  final fixture = SwiftPmBinaryFixture.generate(
    root: arguments[0],
    archiveUrl: Uri.parse(arguments[1]),
  );
  stdout.writeln('archive=${fixture.archive.path}');
  stdout.writeln('checksum=${fixture.checksum}');
  stdout.writeln('plugin=${fixture.pluginRoot.path}');
}
