import 'dart:io';

import 'package:xcross/xcross.dart';

Future<void> main(List<String> args) async {
  final code = await XcrossCli.run(args);
  exit(code);
}
