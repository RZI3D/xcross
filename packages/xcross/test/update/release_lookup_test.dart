import 'package:test/test.dart';
import 'package:xcross/src/update/release_lookup.dart';

void main() {
  test('asset URLs point at the release download path', () {
    expect(
      xcrossAssetBaseUrl('1.3.0'),
      'https://github.com/$xcrossRepo/releases/download/1.3.0',
    );
  });

  group('tagFromReleaseUrl', () {
    test('reads the tag out of a release redirect', () {
      expect(
        ReleaseLookup.tagFromReleaseUrl(
          'https://github.com/$xcrossRepo/releases/tag/1.3.0',
        ),
        '1.3.0',
      );
      expect(
        ReleaseLookup.tagFromReleaseUrl('/arxdeus/xcross/releases/tag/v1.3.0'),
        'v1.3.0',
      );
    });

    // pathSegments percent-decodes, so a tag is only safe to interpolate into
    // a download URL after it has been checked against the release shape.
    test('rejects a tag that is not a release version', () {
      for (final tag in [
        '..%2f..%2fevil',
        'latest',
        'nightly',
        '..',
        '%2e%2e',
      ]) {
        expect(
          ReleaseLookup.tagFromReleaseUrl(
            'https://github.com/$xcrossRepo/releases/tag/$tag',
          ),
          isNull,
          reason: 'expected $tag to be refused',
        );
      }
    });

    // A repository with no releases redirects to the listing page, whose last
    // segment is "releases"; taking it would report that as the latest tag.
    test('returns null when the redirect names no release', () {
      for (final url in [
        'https://github.com/$xcrossRepo/releases',
        'https://github.com/$xcrossRepo/releases/latest',
        'https://github.com/$xcrossRepo/releases/tag/',
        'https://github.com/$xcrossRepo',
      ]) {
        expect(
          ReleaseLookup.tagFromReleaseUrl(url),
          isNull,
          reason: 'expected no tag in $url',
        );
      }
    });
  });
}
