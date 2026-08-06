import 'dart:io';

import 'package:xcross/xcross.dart';

Future<void> main(List<String> args) async {
  final code = await XcrossCli.run(args);
  // Must exit(): setting [exitCode] and returning from main leaves the process
  // alive whenever anything still holds the event loop — most notably
  // ProcessRunner.sharedStdin's paused stdin subscription (pausingBroadcast
  // never cancels the source). That is exactly the silent "stuck after q"
  // hang: session stopped, no more I/O, shell prompt never returns.
  exit(code);
}
