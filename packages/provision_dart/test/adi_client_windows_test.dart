@TestOn('windows')
library adi_client_windows_test;

import 'dart:io';

import 'package:provision_dart/provision_dart.dart';
import 'package:test/test.dart';

void main() {
  // Downloads the real Apple Music APK on first run (not redistributed;
  // see NOTICE.md). Proves Windows VirtualAlloc ELF load + SysV bridge +
  // ADI symbol resolution. Does not call Apple provisioning endpoints.
  test(
    'native ADI library can be fetched, ELF-loaded on Windows, and symbols resolved',
    () async {
      final fetcher = AdiLibraryFetcher();
      final (coreAdiPath, storeServicesPath, apkSha256) =
          await fetcher.ensureLibraries();

      expect(File(coreAdiPath).existsSync(), isTrue);
      expect(File(storeServicesPath).existsSync(), isTrue);
      expect(apkSha256, isNotEmpty);

      final client = AdiClient.fromDirectory(fetcher.cacheDir.path);
      expect(client, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
