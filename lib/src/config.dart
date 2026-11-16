import 'errors.dart';

/// Expands to [defaultInputs] inside a task's `inputs`.
const defaultInputsToken = r'$DEFAULT';

/// Prefix for `inputs` patterns relative to the workspace root instead of the
/// package.
const rootInputPrefix = r'$ROOT/';

/// Files hashed for a task when it doesn't set `inputs`: the places Dart and
/// pub keep a package's sources and configuration.
const defaultInputs = [
  'pubspec.yaml',
  'pubspec_overrides.yaml',
  'analysis_options.yaml',
  'build.yaml',
  'dart_test.yaml',
  'lib/**',
  'bin/**',
  'test/**',
  'tool/**',
  'hook/**',
  'web/**',
  'assets/**',
  'integration_test/**',
];

/// Files hashed for each workspace package a task's package depends on, when
/// the task has `hashDependencies` (the default): what an importer can see.
const dependencyInputs = ['pubspec.yaml', 'lib/**', 'hook/**'];

/// Workspace-root files hashed for every task, unless `globalInputs` is set.
const defaultGlobalInputs = ['pubspec.lock', 'analysis_options.yaml'];

/// How a task's output is shown.
enum OutputLogs {
  /// Everything, replaying cached logs.
  full('full'),

  /// Output of tasks that run; cache hits only say so.
  newOnly('new-only'),

  /// Only the hash of each task.
  hashOnly('hash-only'),

  /// Output of failed tasks only.
  errorsOnly('errors-only'),

  /// Nothing.
  none('none');

  const OutputLogs(this.value);

  final String value;

  static OutputLogs parse(String value, String where) {
    for (final mode in values) {
      if (mode.value == value) return mode;
    }
    throw ConfigException(
      '$where: "$value" isn\'t one of '
      '${values.map((m) => m.value).join(', ')}.',
    );
  }
}

/// A task as written in one place; unset fields inherit from the layer below.
class TaskDef {
  const TaskDef({
    this.run,
    this.dependsOn,
    this.inputs,
    this.outputs,
    this.env,
    this.cache,
    this.hashDependencies,
    this.outputLogs,
  });

  /// Shell commands, run in order in the package's directory.
  final List<String>? run;

  /// `task` (same package), `^task` (workspace dependencies) or
  /// `package#task`.
  final List<String>? dependsOn;

  /// Globs of files whose contents are hashed, relative to the package.
  final List<String>? inputs;

  /// Globs of files saved to the cache, and restored on a hit.
  final List<String>? outputs;

  /// Environment variables whose values are hashed.
  final List<String>? env;

  /// Whether results are cached.
  final bool? cache;

  /// Whether the [dependencyInputs] of workspace dependencies are hashed.
  final bool? hashDependencies;

  final OutputLogs? outputLogs;

  static const _keys = {
    'run',
    'dependsOn',
    'inputs',
    'outputs',
    'env',
    'cache',
    'hashDependencies',
    'outputLogs',
  };

  /// [other]'s fields, falling back to this one's.
  TaskDef merge(TaskDef other) => TaskDef(
    run: other.run ?? run,
    dependsOn: other.dependsOn ?? dependsOn,
    inputs: other.inputs ?? inputs,
    outputs: other.outputs ?? outputs,
    env: other.env ?? env,
    cache: other.cache ?? cache,
    hashDependencies: other.hashDependencies ?? hashDependencies,
    outputLogs: other.outputLogs ?? outputLogs,
  );

  /// Parses a task: a command, a list of commands, or a map of fields.
  static TaskDef parse(Object? raw, String where) {
    if (raw is String || raw is List) {
      return TaskDef(run: _strings(raw, where));
    }
    if (raw == null) return const TaskDef();
    if (raw is! Map) {
      throw ConfigException(
        '$where: expected a command, a list of commands, a map, or false.',
      );
    }
    for (final key in raw.keys) {
      if (!_keys.contains(key)) {
        throw ConfigException(
          '$where: unknown key "$key"; expected one of ${_keys.join(', ')}.',
        );
      }
    }
    final dependsOn = _optStrings(raw['dependsOn'], '$where.dependsOn');
    for (final dep in dependsOn ?? const <String>[]) {
      _checkDependency(dep, '$where.dependsOn');
    }
    return TaskDef(
      run: _optStrings(raw['run'], '$where.run'),
      dependsOn: dependsOn,
      inputs: _optStrings(raw['inputs'], '$where.inputs'),
      outputs: _optStrings(raw['outputs'], '$where.outputs'),
      env: _optStrings(raw['env'], '$where.env'),
      cache: _optBool(raw['cache'], '$where.cache'),
      hashDependencies: _optBool(
        raw['hashDependencies'],
        '$where.hashDependencies',
      ),
      outputLogs: switch (raw['outputLogs']) {
        null => null,
        final String v => OutputLogs.parse(v, '$where.outputLogs'),
        _ => throw ConfigException('$where.outputLogs: expected a string.'),
      },
    );
  }

  static void _checkDependency(String dep, String where) {
    final hash = dep.indexOf('#');
    final ok = hash == -1
        ? dep.replaceFirst('^', '').isNotEmpty && !dep.contains('^', 1)
        : hash > 0 &&
              hash < dep.length - 1 &&
              !dep.startsWith('^') &&
              !dep.contains('#', hash + 1);
    if (!ok) {
      throw ConfigException(
        '$where: "$dep" isn\'t "task", "^task" or "package#task".',
      );
    }
  }
}

/// A task's definition for one package, with every layer merged and defaults
/// filled in.
class ResolvedTask {
  ResolvedTask(TaskDef def)
    : run = def.run ?? const [],
      dependsOn = def.dependsOn ?? const [],
      inputs = def.inputs ?? const [defaultInputsToken],
      outputs = def.outputs ?? const [],
      env = def.env ?? const [],
      cache = def.cache ?? true,
      hashDependencies = def.hashDependencies ?? true,
      outputLogs = def.outputLogs;

  final List<String> run;
  final List<String> dependsOn;
  final List<String> inputs;
  final List<String> outputs;
  final List<String> env;
  final bool cache;
  final bool hashDependencies;
  final OutputLogs? outputLogs;

  /// Whether the task only groups its dependencies.
  bool get isNoop => run.isEmpty;
}

/// Task definitions by name; `null` disables a task.
typedef TaskTable = Map<String, TaskDef?>;

/// The `turbodart` section of the workspace root's pubspec.
class RootConfig {
  RootConfig({
    this.globalInputs = defaultGlobalInputs,
    this.globalEnv = const [],
    this.cacheEntries = 5,
    this.tasks = const {},
    this.packageTasks = const {},
  });

  /// Workspace-root files hashed for every task.
  final List<String> globalInputs;

  /// Environment variables hashed for every task.
  final List<String> globalEnv;

  /// How many results are kept per package and task.
  final int cacheEntries;

  /// Tasks for every package.
  final TaskTable tasks;

  /// `package#task` entries, by package (`//` for the root).
  final Map<String, TaskTable> packageTasks;

  static const _keys = {'globalInputs', 'globalEnv', 'cacheEntries', 'tasks'};

  static RootConfig parse(Object? raw, String where) {
    if (raw == null) return RootConfig();
    if (raw is! Map) throw ConfigException('$where: expected a map.');
    for (final key in raw.keys) {
      if (!_keys.contains(key)) {
        throw ConfigException(
          '$where: unknown key "$key"; expected one of ${_keys.join(', ')}.',
        );
      }
    }
    final cacheEntries = raw['cacheEntries'] ?? 5;
    if (cacheEntries is! int || cacheEntries < 1) {
      throw ConfigException(
        '$where.cacheEntries: expected a positive integer.',
      );
    }
    final packageTasks = <String, TaskTable>{};
    final tasks = parseTasks(
      raw['tasks'],
      '$where.tasks',
      packageTasks: packageTasks,
    );
    return RootConfig(
      globalInputs:
          _optStrings(raw['globalInputs'], '$where.globalInputs') ??
          defaultGlobalInputs,
      globalEnv: _optStrings(raw['globalEnv'], '$where.globalEnv') ?? const [],
      cacheEntries: cacheEntries,
      tasks: tasks,
      packageTasks: packageTasks,
    );
  }
}

/// Parses a `tasks` map. `package#task` keys are only allowed with
/// [packageTasks], which receives them.
TaskTable parseTasks(
  Object? raw,
  String where, {
  Map<String, TaskTable>? packageTasks,
}) {
  if (raw == null) return {};
  if (raw is! Map) throw ConfigException('$where: expected a map.');
  final tasks = <String, TaskDef?>{};
  for (final MapEntry(:key, :value) in raw.entries) {
    if (key is! String || key.isEmpty || key.startsWith('^')) {
      throw ConfigException('$where: "$key" isn\'t a valid task name.');
    }
    final def = value == false ? null : TaskDef.parse(value, '$where.$key');
    final hash = key.indexOf('#');
    if (hash == -1) {
      tasks[key] = def;
      continue;
    }
    final package = key.substring(0, hash);
    final task = key.substring(hash + 1);
    if (packageTasks == null) {
      throw ConfigException(
        '$where.$key: "package#task" keys are only allowed in the workspace '
        'root\'s pubspec.',
      );
    }
    if (package.isEmpty || task.isEmpty || task.contains('#')) {
      throw ConfigException('$where: "$key" isn\'t a valid "package#task".');
    }
    (packageTasks[package] ??= {})[task] = def;
  }
  return tasks;
}

List<String> _strings(Object? raw, String where) {
  if (raw is String) return [raw];
  if (raw is List && raw.every((e) => e is String)) {
    return List.unmodifiable(raw.cast<String>());
  }
  throw ConfigException('$where: expected a string or a list of strings.');
}

List<String>? _optStrings(Object? raw, String where) =>
    raw == null ? null : _strings(raw, where);

bool? _optBool(Object? raw, String where) {
  if (raw == null || raw is bool) return raw as bool?;
  throw ConfigException('$where: expected true or false.');
}
