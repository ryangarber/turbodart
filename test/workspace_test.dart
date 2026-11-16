import 'package:test/test.dart';
import 'package:turbodart/turbodart.dart';

import 'fixture.dart';

void main() {
  group('Workspace.load', () {
    test('finds the root package and globbed members', () {
      final ws = standardWorkspace().load();
      expect(ws.root.name, 'root');
      expect(ws.root.isRoot, isTrue);
      expect(ws.root.path, '.');
      expect(ws.packages.map((p) => p.name), [
        'root',
        'app',
        'core',
        'tool',
        'util',
      ]);
      expect(ws.lookup('core')!.path, 'packages/core');
      expect(ws.lookup('//'), ws.root);
    });

    test('finds the root from inside a member', () {
      final fixture = standardWorkspace();
      final ws = fixture.load('packages/core/lib');
      expect(ws.rootDir, fixture.dir);
    });

    test('treats a pubspec without a workspace as a single package', () {
      final fixture = Fixture.create({
        'pubspec.yaml': pubspec('solo', member: false),
      });
      expect(fixture.load().packages.map((p) => p.name), ['solo']);
    });

    test('loads nested workspaces', () {
      final fixture = Fixture.create({
        'pubspec.yaml': pubspec('root', member: false, workspace: ['outer']),
        'outer/pubspec.yaml': pubspec('outer', workspace: ['inner']),
        'outer/inner/pubspec.yaml': pubspec('inner'),
      });
      expect(fixture.load('outer/inner').packages.map((p) => p.name), [
        'root',
        'outer',
        'inner',
      ]);
    });

    test('rejects a listed member without a pubspec', () {
      final fixture = Fixture.create({
        'pubspec.yaml': pubspec('root', member: false, workspace: ['missing']),
      });
      expect(fixture.load, throwsA(isA<ConfigException>()));
    });

    test('rejects duplicate names', () {
      final fixture = Fixture.create({
        'pubspec.yaml': pubspec('root', member: false, workspace: ['a', 'b']),
        'a/pubspec.yaml': pubspec('same'),
        'b/pubspec.yaml': pubspec('same'),
      });
      expect(
        fixture.load,
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('same'),
          ),
        ),
      );
    });

    test('rejects root-only keys in a member', () {
      final fixture = standardWorkspace(
        extra: {
          'packages/util/pubspec.yaml': pubspec(
            'util',
            turbodart: '  globalEnv: [CI]',
          ),
        },
      );
      expect(fixture.load, throwsA(isA<ConfigException>()));
    });
  });

  group('dependencies', () {
    test('transitive dependencies include dev ones only directly', () {
      final ws = standardWorkspace().load();
      Set<String> deps(String name) => ws
          .transitiveDependencies(ws.lookup(name)!)
          .map((p) => p.name)
          .toSet();
      expect(deps('app'), {'core', 'util'});
      expect(deps('tool'), {'core', 'util'});
      expect(deps('util'), isEmpty);
      expect(
        ws.transitiveDependents(ws.lookup('util')!).map((p) => p.name).toSet(),
        {'core', 'app', 'tool'},
      );
    });
  });

  group('taskFor', () {
    test('layers the shared, package#task, and package definitions', () {
      final fixture = standardWorkspace(
        tasks: '''
    test:
      run: dart test
      env: [A]
    core#test:
      env: [B]
    "//#test": false
''',
        extra: {
          'packages/core/pubspec.yaml': pubspec(
            'core',
            dependencies: ['util'],
            turbodart: '  tasks:\n    test:\n      outputs: [coverage/**]',
          ),
          'packages/util/pubspec.yaml': pubspec(
            'util',
            turbodart:
                '  tasks:\n    test: false\n    gen: dart run tool/gen.dart',
          ),
        },
      );
      final ws = fixture.load();
      final core = ws.taskFor(ws.lookup('core')!, 'test')!;
      expect(core.run, ['dart test']);
      expect(core.env, ['B']);
      expect(core.outputs, ['coverage/**']);
      expect(ws.taskFor(ws.lookup('app')!, 'test')!.env, ['A']);
      expect(ws.taskFor(ws.lookup('util')!, 'test'), isNull);
      expect(ws.taskFor(ws.root, 'test'), isNull);
      expect(ws.taskFor(ws.lookup('util')!, 'gen')!.run, [
        'dart run tool/gen.dart',
      ]);
      expect(ws.taskFor(ws.lookup('app')!, 'gen'), isNull);
    });

    test('rejects unknown keys with their location', () {
      final fixture = standardWorkspace(tasks: '    test:\n      rn: x\n');
      expect(
        fixture.load,
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('turbodart.tasks.test'), contains('"rn"')),
          ),
        ),
      );
    });

    test('rejects package#task for unknown packages', () {
      final fixture = standardWorkspace(tasks: '    nope#test: x\n');
      expect(fixture.load, throwsA(isA<ConfigException>()));
    });
  });
}
