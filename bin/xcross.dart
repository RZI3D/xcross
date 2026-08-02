import 'dart:io';

import 'package:xcross/xcross.dart';

Future<void> main(List<String> args) async {
  final code = await XcrossCli.run(args);
  // Exit explicitly rather than falling off the end of main: a single lingering
  // handle (a Timer, a signal subscription, a listening socket) keeps the Dart
  // event loop alive and the process hangs after all work is done. That has
  // bitten this tool repeatedly. Do not flush stdout/stderr here — on Windows
  // AOT a prior stdin.readLineSync can leave those IOSinks "bound to a stream"
  // so flush throws an unhandled exception after a clean CLI error path.
  exit(code);
}
