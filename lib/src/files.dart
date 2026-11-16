import 'dart:collection';
import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

import 'errors.dart';

/// Directories never walked into: VCS metadata, pub's and turbodart's own
/// state. A pattern can still reach inside one by naming it, e.g.
/// `.dart_tool/build/**`.
const _skippedNames = {'.git', '.dart_tool', '.turbodart'};

final _globChars = RegExp(r'[*?\[{]');

/// Whether [pattern] has glob syntax rather than naming a path.
bool isGlob(String pattern) => _globChars.hasMatch(pattern);

/// [pattern] with `./` and duplicate slashes removed, checked to stay within
/// its base directory.
String normalizePattern(String pattern, String where) {
  if (pattern.contains(r'\')) {
    throw ConfigException(
      '$where: "$pattern" must use "/" to separate directories.',
    );
  }
  final normalized = p.posix.normalize(pattern);
  if (p.posix.isAbsolute(normalized) ||
      normalized == '..' ||
      normalized.startsWith('../')) {
    throw ConfigException(
      '$where: "$pattern" must be relative and stay within its directory.',
    );
  }
  return normalized;
}

/// The files under [baseDir] matched by [patterns], as sorted `/`-separated
/// paths relative to it. Patterns starting with `!` exclude what they match.
///
/// Paths are the same on every OS, and [skipDir] (given absolute paths) can
/// keep the walk out of directories, e.g. nested packages.
List<String> matchFiles(
  String baseDir,
  Iterable<String> patterns, {
  bool Function(String dir)? skipDir,
  String where = 'inputs',
}) {
  final includes = <String>[];
  final excludes = <String>[];
  for (final raw in patterns) {
    final negated = raw.startsWith('!');
    final pattern = normalizePattern(negated ? raw.substring(1) : raw, where);
    (negated ? excludes : includes).add(pattern);
  }

  final found = SplayTreeSet<String>();
  for (final pattern in includes) {
    final segments = pattern.split('/');
    final firstGlob = segments.indexWhere(isGlob);
    if (firstGlob == -1) {
      final path = p.join(baseDir, pattern);
      if (pattern == '.' || FileSystemEntity.isDirectorySync(path)) {
        found.addAll(walk(baseDir, pattern == '.' ? '' : pattern, skipDir));
      } else if (FileSystemEntity.isFileSync(path)) {
        found.add(pattern);
      }
      continue;
    }
    final glob = Glob(pattern, context: p.posix);
    final prefix = segments.take(firstGlob).join('/');
    found.addAll(walk(baseDir, prefix, skipDir).where(glob.matches));
  }

  if (excludes.isEmpty) return found.toList();
  final excluded = [
    for (final pattern in excludes)
      if (isGlob(pattern))
        Glob(pattern, context: p.posix).matches
      else
        (String path) =>
            pattern == '.' || path == pattern || path.startsWith('$pattern/'),
  ];
  return found.where((path) => !excluded.any((match) => match(path))).toList();
}

/// The files (or with [directories], the directories) under `baseDir/start`,
/// as `/`-separated paths relative to [baseDir]. Symlinked directories aren't
/// followed.
Iterable<String> walk(
  String baseDir,
  String start,
  bool Function(String dir)? skipDir, {
  bool directories = false,
}) sync* {
  final root = start.isEmpty ? baseDir : p.join(baseDir, start);
  if (!FileSystemEntity.isDirectorySync(root)) return;
  final pending = [(root, start)];
  while (pending.isNotEmpty) {
    final (dir, rel) = pending.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final entity in entries) {
      final name = p.basename(entity.path);
      final childRel = rel.isEmpty ? name : '$rel/$name';
      if (entity is Directory) {
        if (_skippedNames.contains(name)) continue;
        if (skipDir != null && skipDir(entity.path)) continue;
        if (directories) yield childRel;
        pending.add((entity.path, childRel));
      } else if (!directories &&
          (entity is File ||
              (entity is Link && FileSystemEntity.isFileSync(entity.path)))) {
        yield childRel;
      }
    }
  }
}
