import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:turbodart/turbodart.dart';

/// A workspace in a temporary directory, deleted after the test.
class Fixture {
  Fixture._(this.dir);

  final String dir;

  /// Creates files from [files], keyed by `/`-separated paths.
  static Fixture create(Map<String, String> files) {
    final dir = Directory.systemTemp.createTempSync('turbodart_test_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final fixture = Fixture._(p.normalize(dir.resolveSymbolicLinksSync()));
    files.forEach(fixture.write);
    return fixture;
  }

  String path(String rel) => p.joinAll([dir, ...rel.split('/')]);

  void write(String rel, String contents) {
    final file = File(path(rel));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  String read(String rel) => File(path(rel)).readAsStringSync();

  bool exists(String rel) => File(path(rel)).existsSync();

  void delete(String rel) => File(path(rel)).deleteSync();

  Workspace load([String rel = '']) => Workspace.load(path(rel));

  /// Runs the command line in [cwd], returning its exit code and output.
  Future<(int, String)> run(List<String> args, {String cwd = ''}) async {
    final out = StringBuffer();
    final code = await runTurbodart(
      args,
      cwd: path(cwd),
      console: Console(out: out, err: out, color: false),
    );
    return (code, out.toString());
  }
}

String pubspec(
  String name, {
  bool member = true,
  List<String> workspace = const [],
  List<String> dependencies = const [],
  List<String> devDependencies = const [],
  String turbodart = '',
}) {
  final out = StringBuffer('name: $name\nenvironment:\n  sdk: ^3.10.0\n');
  if (member) out.writeln('resolution: workspace');
  if (workspace.isNotEmpty) {
    out.writeln('workspace:');
    for (final entry in workspace) {
      out.writeln('  - $entry');
    }
  }
  for (final (key, deps) in [
    ('dependencies', dependencies),
    ('dev_dependencies', devDependencies),
  ]) {
    if (deps.isEmpty) continue;
    out.writeln('$key:');
    for (final dep in deps) {
      out.writeln('  $dep: any');
    }
  }
  if (turbodart.isNotEmpty) out.writeln('turbodart:\n$turbodart');
  return out.toString();
}

/// A workspace of `app` → `core` → `util`, plus `tool` (dev-depends on
/// `core`), all running [tasks] from the root.
Fixture standardWorkspace({
  String tasks = '',
  Map<String, String> extra = const {},
}) => Fixture.create({
  'pubspec.yaml': pubspec(
    'root',
    member: false,
    workspace: ['packages/*'],
    turbodart: '  tasks:\n$tasks',
  ),
  'packages/util/pubspec.yaml': pubspec('util'),
  'packages/util/lib/util.dart': 'const util = 1;\n',
  'packages/core/pubspec.yaml': pubspec('core', dependencies: ['util']),
  'packages/core/lib/core.dart': 'const core = 1;\n',
  'packages/app/pubspec.yaml': pubspec('app', dependencies: ['core']),
  'packages/app/lib/app.dart': 'const app = 1;\n',
  'packages/tool/pubspec.yaml': pubspec('tool', devDependencies: ['core']),
  ...extra,
});
