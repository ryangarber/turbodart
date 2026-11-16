import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'files.dart';
import 'task_graph.dart';
import 'workspace.dart';

/// Bumped when what goes into a hash changes, so older results aren't used.
const cacheFormatVersion = 1;

/// Hashes tasks from everything that determines their result.
///
/// Hashes are the same on every OS and architecture: paths are `/`-separated
/// and sorted, line endings are normalized, and only the Dart SDK's version
/// (not its platform) is included.
class TaskHasher {
  TaskHasher(
    this.workspace, {
    String? sdkVersion,
    Map<String, String>? environment,
  }) : sdkVersion = sdkVersion ?? Platform.version.split(' ').first,
       environment = environment ?? Platform.environment;

  final Workspace workspace;
  final String sdkVersion;
  final Map<String, String> environment;

  final _fileHashes = <String, (FileStat, String)>{};
  final _packageHashes = <Package, String>{};

  /// The hash of [node] given its dependencies' hashes, in the order of
  /// `node.dependencies`, and the arguments passed to it.
  String hash(
    TaskNode node,
    List<String> dependencyHashes, {
    List<String> args = const [],
  }) {
    final def = node.def;
    final dependencies = [
      for (final (i, dep) in node.dependencies.indexed)
        (dep.id, dependencyHashes[i]),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final payload = {
      'format': cacheFormatVersion,
      'sdk': sdkVersion,
      'package': node.package.path,
      'task': node.task,
      'run': def.run,
      'args': args,
      'inputs': def.inputs,
      'outputs': def.outputs,
      'env': _env({...workspace.config.globalEnv, ...def.env}),
      'global': _files(
        workspace.rootDir,
        matchFiles(
          workspace.rootDir,
          workspace.config.globalInputs,
          where: 'globalInputs',
        ),
      ),
      'files': inputHashes(node.package, def),
      'packages': {
        if (def.hashDependencies)
          for (final dep in workspace.transitiveDependencies(node.package))
            dep.name: packageHash(dep),
      },
      'dependsOn': {for (final (id, hash) in dependencies) id: hash},
    };
    return _digest(utf8.encode(_canonicalJson(payload))).substring(0, 16);
  }

  /// The hashes of the task's input files: paths relative to the package, or
  /// to the workspace root as `$ROOT/path`. Its outputs are left out, so
  /// running it doesn't change its own hash.
  Map<String, String> inputHashes(Package package, ResolvedTask def) {
    final local = <String>[];
    final fromRoot = <String>[];
    for (final pattern in def.inputs) {
      final negated = pattern.startsWith('!');
      final body = negated ? pattern.substring(1) : pattern;
      if (body == defaultInputsToken) {
        if (!negated) local.addAll(defaultInputs);
      } else if (body.startsWith(rootInputPrefix)) {
        fromRoot.add(
          '${negated ? '!' : ''}${body.substring(rootInputPrefix.length)}',
        );
      } else {
        local.add(pattern);
      }
    }
    final excludeOutputs = [
      for (final output in def.outputs)
        if (!output.startsWith('!')) '!$output',
    ];
    final hashes = _files(
      package.dir,
      matchFiles(package.dir, [
        ...local,
        ...excludeOutputs,
      ], skipDir: (dir) => workspace.isNestedPackage(package, dir)),
    );
    if (fromRoot.isNotEmpty) {
      final rootFiles = matchFiles(workspace.rootDir, fromRoot);
      _files(workspace.rootDir, rootFiles).forEach((path, hash) {
        hashes['$rootInputPrefix$path'] = hash;
      });
    }
    return hashes;
  }

  /// The hash of what packages depending on [package] see of it.
  String packageHash(Package package) => _packageHashes[package] ??= _digest(
    utf8.encode(
      _canonicalJson(
        _files(
          package.dir,
          matchFiles(
            package.dir,
            dependencyInputs,
            skipDir: (dir) => workspace.isNestedPackage(package, dir),
          ),
        ),
      ),
    ),
  );

  /// Forgets what's known about [package]'s files, after a task changed them.
  void invalidate(Package package) => _packageHashes.remove(package);

  /// The hash of a file's contents, with `\r\n` read as `\n` so checkouts
  /// with either line ending hash the same.
  String fileHash(String path) {
    final stat = FileStat.statSync(path);
    final cached = _fileHashes[path];
    if (cached != null &&
        cached.$1.modified == stat.modified &&
        cached.$1.size == stat.size) {
      return cached.$2;
    }
    final hash = _digest(normalizeLineEndings(File(path).readAsBytesSync()));
    _fileHashes[path] = (stat, hash);
    return hash;
  }

  Map<String, String> _files(String baseDir, List<String> paths) => {
    for (final path in paths)
      path: fileHash(p.joinAll([baseDir, ...path.split('/')])),
  };

  Map<String, String?> _env(Set<String> names) => {
    for (final name in names.toList()..sort())
      name: switch (environment[name]) {
        final value? => _digest(utf8.encode(value)),
        null => null,
      },
  };
}

/// [bytes] with every `\r\n` replaced by `\n`.
Uint8List normalizeLineEndings(Uint8List bytes) {
  final cr = bytes.indexOf(13);
  if (cr == -1) return bytes;
  final out = BytesBuilder(copy: false);
  var start = 0;
  for (var i = cr; i < bytes.length - 1; i++) {
    if (bytes[i] == 13 && bytes[i + 1] == 10) {
      out.add(Uint8List.sublistView(bytes, start, i));
      start = i + 1;
    }
  }
  out.add(Uint8List.sublistView(bytes, start));
  return out.takeBytes();
}

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

/// JSON with map keys sorted, so equal values always encode the same.
String _canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) => switch (value) {
  final Map<Object?, Object?> map => {
    for (final key in map.keys.map((k) => '$k').toList()..sort())
      key: _sorted(map[key]),
  },
  final List<Object?> list => list.map(_sorted).toList(),
  _ => value,
};
