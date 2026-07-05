import 'dart:io';

import 'package:xcross/src/cli/runner.dart';

Future<void> main(List<String> args) async {
  exitCode = await runXcross(args);
}
