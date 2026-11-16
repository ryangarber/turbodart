import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:turbodart/turbodart.dart';

import 'fixture.dart';

void main() {
  late Fixture fixture;

  setUp(() {
    fixture = standardWorkspace(
      tasks: '''
    build:
      run: echo build
      outputs: [lib/gen/**]
      env: [MODE]
    narrow:
      run: echo narrow
      inputs: [lib/core.dart, "!lib/**/*.g.dart", "\$ROOT/shared/**"]
      hashDependencies: false
''',
      extra: {'shared/config.txt': 'shared\n'},
    );
  });

  String hash(
    String package,
    String task, {
    Map<String, String> env = const {},
    String sdk = '3.10.0',
  }) {
    final ws = fixture.load();
    final node = TaskGraph.build(
      ws,
      packages: [ws.lookup(package)!],
      tasks: [task],
    ).nodes.single;
    return TaskHasher(ws, sdkVersion: sdk, environment: env).hash(node, []);
  }

  test('is stable, and changes with the inputs', () {
    final before = hash('core', 'build');
    expect(hash('core', 'build'), before);
    fixture.write('packages/core/lib/core.dart', 'const core = 2;\n');
    expect(hash('core', 'build'), isNot(before));
  });

  test('ignores line endings', () {
    final before = hash('core', 'build');
    fixture.write('packages/core/lib/core.dart', 'const core = 1;\r\n');
    expect(hash('core', 'build'), before);
  });

  test('ignores files outside the inputs and the outputs', () {
    final before = hash('core', 'build');
    fixture.write('packages/core/README.md', 'readme');
    fixture.write('packages/core/lib/gen/out.dart', 'generated');
    fixture.write('packages/core/.dart_tool/x', 'x');
    fixture.write('packages/core/.turbodart/x', 'x');
    expect(hash('core', 'build'), before);
  });

  test('includes workspace dependencies\' sources, unless disabled', () {
    final build = hash('app', 'build');
    final narrow = hash('core', 'narrow');
    fixture.write('packages/util/lib/util.dart', 'const util = 2;\n');
    expect(hash('app', 'build'), isNot(build));
    expect(hash('core', 'narrow'), narrow);
  });

  test('does not include nested packages\' files', () {
    final before = hash('root', 'build');
    fixture.write('packages/core/test/x_test.dart', 'void main() {}');
    expect(hash('root', 'build'), before);
  });

  test('honors explicit inputs, negations and \$ROOT', () {
    final before = hash('core', 'narrow');
    fixture.write('packages/core/lib/x.g.dart', 'x');
    fixture.write('packages/core/lib/other.dart', 'x');
    expect(hash('core', 'narrow'), before);
    fixture.write('shared/config.txt', 'changed\n');
    expect(hash('core', 'narrow'), isNot(before));
  });

  test('includes global inputs, env values and the SDK version', () {
    final before = hash('core', 'build');
    expect(hash('core', 'build', env: {'MODE': 'x'}), isNot(before));
    expect(hash('core', 'build', env: {'OTHER': 'x'}), before);
    expect(hash('core', 'build', sdk: '3.11.0'), isNot(before));
    fixture.write('pubspec.lock', 'packages: {}\n');
    expect(hash('core', 'build'), isNot(before));
  });

  test('normalizeLineEndings only rewrites CRLF', () {
    String norm(String s) =>
        utf8.decode(normalizeLineEndings(Uint8List.fromList(utf8.encode(s))));
    expect(norm('a\r\nb\rc\n\r\n'), 'a\nb\rc\n\n');
    expect(norm('plain'), 'plain');
  });

  test('safeFileName is valid everywhere and unambiguous', () {
    expect(safeFileName('build'), 'build');
    expect(safeFileName('build:web'), 'build_3aweb');
    expect(safeFileName('a_b'), 'a_5fb');
    expect(safeFileName('.hidden'), '_2ehidden');
  });
}
