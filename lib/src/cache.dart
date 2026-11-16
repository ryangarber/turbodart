import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'files.dart';
import 'workspace.dart';

/// The directory turbodart keeps its state in, inside each package.
const stateDirName = '.turbodart';

/// A cached result: the task's log and outputs.
class CacheEntry {
  CacheEntry._(this.dir, this.hash, this.outputs, this.duration);

  final String dir;
  final String hash;

  /// The cached outputs, relative to the package.
  final List<String> outputs;

  /// How long the task took when it ran.
  final Duration duration;

  String get log => File(p.join(dir, 'output.log')).readAsStringSync();
}

/// Results of each package's tasks, kept in its `.turbodart/cache`.
///
/// Each result is `.turbodart/cache/<task>/<hash>/`, holding `meta.json`,
/// `output.log`, and the outputs under `outputs/`. The latest log of each
/// task, cached or not, is `.turbodart/<task>.log`.
class TaskCache {
  TaskCache({this.maxEntries = 5});

  /// How many results are kept per package and task; the least recently
  /// used go first.
  final int maxEntries;

  static String stateDir(Package package) => p.join(package.dir, stateDirName);

  String _taskDir(Package package, String task) =>
      p.join(stateDir(package), 'cache', safeFileName(task));

  /// The result of [task] in [package] with [hash], if there is one.
  CacheEntry? lookup(Package package, String task, String hash) {
    final dir = p.join(_taskDir(package, task), hash);
    final meta = File(p.join(dir, 'meta.json'));
    if (!meta.existsSync()) return null;
    try {
      final json = jsonDecode(meta.readAsStringSync()) as Map<String, Object?>;
      if (json['hash'] != hash) return null;
      final entry = CacheEntry._(
        dir,
        hash,
        (json['outputs'] as List).cast<String>(),
        Duration(milliseconds: json['durationMs'] as int),
      );
      json['lastUsed'] = DateTime.now().toUtc().toIso8601String();
      meta.writeAsStringSync(jsonEncode(json));
      return entry;
    } on Object {
      return null;
    }
  }

  /// Copies [entry]'s outputs back into [package].
  void restore(Package package, CacheEntry entry) {
    for (final path in entry.outputs) {
      final segments = path.split('/');
      final target = File(p.joinAll([package.dir, ...segments]));
      target.parent.createSync(recursive: true);
      File(
        p.joinAll([entry.dir, 'outputs', ...segments]),
      ).copySync(target.path);
    }
  }

  /// Saves a successful run of [task]: its [log] and the files matching
  /// [outputs].
  void save(
    Package package,
    String task,
    String hash, {
    required String log,
    required List<String> outputs,
    required Duration duration,
    required bool Function(String dir) skipDir,
  }) {
    _ensureStateDir(package);
    final taskDir = _taskDir(package, task);
    final dir = p.join(taskDir, hash);
    final staging = Directory('$dir.tmp-$pid');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    staging.createSync(recursive: true);

    final files = outputs.isEmpty
        ? const <String>[]
        : matchFiles(package.dir, outputs, skipDir: skipDir, where: 'outputs');
    for (final path in files) {
      final segments = path.split('/');
      final target = File(p.joinAll([staging.path, 'outputs', ...segments]));
      target.parent.createSync(recursive: true);
      File(p.joinAll([package.dir, ...segments])).copySync(target.path);
    }
    File(p.join(staging.path, 'output.log')).writeAsStringSync(log);
    final now = DateTime.now().toUtc().toIso8601String();
    File(p.join(staging.path, 'meta.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'hash': hash,
        'task': task,
        'package': package.name,
        'outputs': files,
        'durationMs': duration.inMilliseconds,
        'created': now,
        'lastUsed': now,
      }),
    );

    final existing = Directory(dir);
    if (existing.existsSync()) existing.deleteSync(recursive: true);
    staging.renameSync(dir);
    _prune(taskDir);
  }

  /// Writes the latest log of [task].
  void writeLog(Package package, String task, String log) {
    _ensureStateDir(package);
    File(
      p.join(stateDir(package), '${safeFileName(task)}.log'),
    ).writeAsStringSync(log);
  }

  /// Deletes [package]'s state directory.
  static bool clean(Package package) {
    final dir = Directory(stateDir(package));
    if (!dir.existsSync()) return false;
    dir.deleteSync(recursive: true);
    return true;
  }

  void _ensureStateDir(Package package) {
    final ignore = File(p.join(stateDir(package), '.gitignore'));
    if (ignore.existsSync()) return;
    ignore.parent.createSync(recursive: true);
    ignore.writeAsStringSync('# Created by turbodart.\n*\n');
  }

  void _prune(String taskDir) {
    final entries = <(String, String)>[];
    for (final dir in Directory(taskDir).listSync().whereType<Directory>()) {
      if (dir.path.contains('.tmp-')) continue;
      var lastUsed = '';
      try {
        final meta = File(p.join(dir.path, 'meta.json')).readAsStringSync();
        lastUsed =
            (jsonDecode(meta) as Map<String, Object?>)['lastUsed'] as String;
      } on Object {
        // An unreadable entry sorts first, so it's pruned first.
      }
      entries.add((lastUsed, dir.path));
    }
    entries.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, dir) in entries.skip(maxEntries)) {
      try {
        Directory(dir).deleteSync(recursive: true);
      } on FileSystemException {
        // Another run may be using it; it'll be pruned next time.
      }
    }
  }
}

/// [name] with anything but ASCII letters, digits, `.` and `-` written as
/// `_xx` (each UTF-8 byte in hex), so it's a valid file name everywhere,
/// e.g. `build:web` is `build_3aweb`.
String safeFileName(String name) {
  final out = StringBuffer();
  for (final byte in utf8.encode(name)) {
    final c = String.fromCharCode(byte);
    if (RegExp(r'[A-Za-z0-9.\-]').hasMatch(c) && byte < 128) {
      out.write(c);
    } else {
      out.write('_${byte.toRadixString(16).padLeft(2, '0')}');
    }
  }
  final safe = out.toString();
  return safe.startsWith('.') ? '_2e${safe.substring(1)}' : safe;
}
