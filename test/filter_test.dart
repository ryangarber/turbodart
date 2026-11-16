import 'package:test/test.dart';
import 'package:turbodart/turbodart.dart';

import 'fixture.dart';

void main() {
  late Fixture fixture;
  late Workspace ws;

  setUp(() {
    fixture = standardWorkspace();
    ws = fixture.load();
  });

  List<String> select(
    List<String> filters, {
    String cwd = '',
    List<String> changed = const [],
  }) => filterPackages(
    ws,
    filters,
    cwd: fixture.path(cwd),
    changedFiles: (_, _) => changed,
  ).map((p) => p.name).toList();

  test('no filters select everything', () {
    expect(select([]), ['root', 'app', 'core', 'tool', 'util']);
  });

  test('by name, glob, and root', () {
    expect(select(['core']), ['core']);
    expect(select(['*o*']), ['root', 'core', 'tool']);
    expect(select(['//']), ['root']);
  });

  test('with dependencies and dependents', () {
    expect(select(['app...']), ['app', 'core', 'util']);
    expect(select(['app^...']), ['core', 'util']);
    expect(select(['...core']), ['app', 'core', 'tool']);
    expect(select(['...^core']), ['app', 'tool']);
  });

  test('by path, relative to the current directory', () {
    expect(select(['./packages/core']), ['core']);
    expect(select(['{packages/*}']), ['app', 'core', 'tool', 'util']);
    expect(select(['{.}']), ['root']);
    expect(select(['../util'], cwd: 'packages/core'), ['util']);
  });

  test('exclusions', () {
    expect(select(['!core']), ['root', 'app', 'tool', 'util']);
    expect(select(['app...', '!util']), ['app', 'core']);
  });

  test('by changed files', () {
    expect(
      select(['[main]'], changed: ['packages/util/lib/util.dart', 'README.md']),
      ['root', 'util'],
    );
    expect(select(['...[main]'], changed: ['packages/util/lib/util.dart']), [
      'app',
      'core',
      'tool',
      'util',
    ]);
    expect(select(['{packages/*}[main]'], changed: ['README.md']), isEmpty);
  });

  test('parses selectors', () {
    final s = Selector.parse('!...^{./packages/*}[main...HEAD]');
    expect(s.exclude, isTrue);
    expect(s.dependents, isTrue);
    expect(s.excludeSelf, isTrue);
    expect(s.path, './packages/*');
    expect(s.gitRange, 'main...HEAD');
    expect(() => Selector.parse('...'), throwsA(isA<UsageException>()));
  });
}
