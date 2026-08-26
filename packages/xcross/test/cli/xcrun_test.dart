import 'package:test/test.dart';

import '../../bin/xcrun.dart' as xcrun;

void main() {
  test('rejects an invocation without a tool', () async {
    expect(await xcrun.runXcrun(const []), 1);
  });
}
