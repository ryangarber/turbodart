import 'dart:convert';

import 'package:test/test.dart';
import 'package:turbodart/turbodart.dart';

import 'fixture.dart';

// Commands here work the same in sh and cmd.
void main() {
  late Fixture fixture;

  setUp(() {
    fixture = standardWorkspace(
      tasks: '''
    build:
      run: echo built> out.txt
      dependsOn: [^build]
      outputs: [out.txt]
    test:
      run: echo testing
      dependsOn: [build]
    fail:
      run: exit 3
    "//#build": false
    "//#test": false
    "//#fail": false
''',
    );
  });

  test('runs tasks, then replays them from the cache', () async {
    var (code, out) = await fixture.run(['run', 'test', '--filter', 'app']);
    expect(code, 0, reason: out);
    expect(out, contains('util:build: cache miss, executing'));
    expect(out, contains('app:test: testing'));
    expect(out, contains('4 successful, 4 total'));
    expect(fixture.exists('packages/core/out.txt'), isTrue);
    expect(fixture.exists('packages/core/.turbodart/.gitignore'), isTrue);
    expect(
      fixture.read('packages/app/.turbodart/test.log'),
      contains('testing'),
    );

    fixture.delete('packages/core/out.txt');
    (code, out) = await fixture.run(['test', '-F', 'app']);
    expect(code, 0, reason: out);
    expect(out, contains('app:test: cache hit, replaying logs'));
    expect(out, contains('app:test: testing'));
    expect(out, contains('4 cached, 4 total'));
    expect(fixture.exists('packages/core/out.txt'), isTrue, reason: 'restored');

    fixture.write('packages/util/lib/util.dart', 'const util = 2;\n');
    (code, out) = await fixture.run([
      'test',
      '-F',
      'app',
      '--output-logs=new-only',
    ]);
    expect(out, contains('util:build: cache miss'));
    expect(out, contains('core:build: cache miss'));
    expect(out, isNot(contains('replaying')));
  });

  test('--force and --no-cache', () async {
    await fixture.run(['build', '-F', 'util']);
    var (_, out) = await fixture.run(['build', '-F', 'util', '--force']);
    expect(out, contains('cache bypass, force executing'));
    fixture.write('packages/util/lib/util.dart', 'const util = 3;\n');
    await fixture.run(['build', '-F', 'util', '--no-cache']);
    (_, out) = await fixture.run(['build', '-F', 'util']);
    expect(out, contains('cache miss'));
  });

  test('fails with the task\'s exit code, without caching', () async {
    var (code, out) = await fixture.run(['fail', '-F', 'util']);
    expect(code, 1);
    expect(out, contains('util:fail: command (exit 3) exited (3)'));
    expect(out, contains('Failed:  util#fail'));
    (code, out) = await fixture.run(['fail', '-F', 'util']);
    expect(out, contains('cache miss'));
  });

  test('skips dependents of failed tasks', () async {
    fixture.write(
      'packages/util/pubspec.yaml',
      pubspec('util', turbodart: '  tasks:\n    build: exit 1'),
    );
    final (code, out) = await fixture.run(['test', '-F', 'app', '--continue']);
    expect(code, 1);
    expect(out, contains('Failed:  util#build'));
    expect(out, contains('Skipped:  3'));
    expect(out, isNot(contains('core:build')));
  });

  test('--continue keeps running independent tasks', () async {
    fixture.write(
      'packages/util/pubspec.yaml',
      pubspec('util', turbodart: '  tasks:\n    test: exit 1'),
    );
    final (code, out) = await fixture.run([
      'test',
      '-F',
      'app...',
      '--continue',
      '--concurrency=1',
    ]);
    expect(code, 1, reason: out);
    expect(out, contains('Failed:  util#test'));
    expect(out, contains('app:test: testing'));
  });

  test('passes arguments after -- to the tasks asked for', () async {
    final (code, out) = await fixture.run(['test', '-F', 'app', '--', 'hello']);
    expect(code, 0, reason: out);
    expect(out, contains('app:test: testing hello'));
    expect(out, contains('core:build: cache miss'));
  });

  test('scopes to the package in the current directory', () async {
    final (code, out) = await fixture.run(['test'], cwd: 'packages/util/lib');
    expect(code, 0, reason: out);
    expect(out, contains('2 successful, 2 total'));
  });

  test('--dry-run --json shows the plan without running', () async {
    final (code, out) = await fixture.run([
      'run',
      'test',
      '-F',
      'core',
      '--dry-run',
      '--json',
    ]);
    expect(code, 0, reason: out);
    final json = jsonDecode(out) as Map<String, Object?>;
    final tasks = (json['tasks'] as List).cast<Map<String, Object?>>();
    expect(tasks.map((t) => t['id']), [
      'util#build',
      'core#build',
      'core#test',
    ]);
    expect(tasks.every((t) => t['cached'] == false), isTrue);
    expect(fixture.exists('packages/core/out.txt'), isFalse);
  });

  test('ls lists packages and tasks', () async {
    final (code, out) = await fixture.run(['ls', '--json']);
    expect(code, 0, reason: out);
    final packages = ((jsonDecode(out) as Map)['packages'] as List)
        .cast<Map<String, Object?>>();
    expect(packages.first['name'], 'root');
    expect(packages.first['tasks'], isEmpty);
    expect(packages[1]['tasks'], ['build', 'fail', 'test']);
    expect(packages[1]['dependencies'], ['core']);
  });

  test('clean deletes caches', () async {
    await fixture.run(['build', '-F', 'util']);
    expect(fixture.exists('packages/util/.turbodart/build.log'), isTrue);
    final (code, out) = await fixture.run(['clean']);
    expect(code, 0);
    expect(out, contains('Deleted packages/util/.turbodart'));
    expect(fixture.exists('packages/util/.turbodart/build.log'), isFalse);
  });

  test('reports usage and config errors', () async {
    var (code, out) = await fixture.run(['run', 'nope']);
    expect(code, 64);
    expect(out, contains('There\'s no task "nope"'));
    (code, out) = await fixture.run(['run']);
    expect(code, 64);
    (code, out) = await fixture.run(['--version']);
    expect(out.trim(), packageVersion);
    fixture.write('pubspec.yaml', 'name: root\nturbodart:\n  tasks: [x]\n');
    (code, out) = await fixture.run(['ls']);
    expect(code, 1);
    expect(out, contains('turbodart.tasks: expected a map'));
  });
}
