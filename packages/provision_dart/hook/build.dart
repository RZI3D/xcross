import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final cBuilder = CBuilder.library(
      name: 'sysv_abi_bridge',
      assetName: 'src/loader/sysv_abi_bridge.dart',
      sources: const ['src/sysv_abi_bridge.c'],
    );
    await cBuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.INFO
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
