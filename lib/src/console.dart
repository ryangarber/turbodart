import 'dart:io';

/// Where turbodart writes, and whether it uses color.
class Console {
  Console({StringSink? out, StringSink? err, bool? color})
    : out = out ?? stdout,
      err = err ?? stderr,
      color = color ?? _detectColor();

  final StringSink out;
  final StringSink err;
  final bool color;

  static bool _detectColor() {
    final env = Platform.environment;
    if (env.containsKey('NO_COLOR')) return false;
    if (env.containsKey('FORCE_COLOR') || env.containsKey('GITHUB_ACTIONS')) {
      return true;
    }
    return stdout.hasTerminal && stdout.supportsAnsiEscapes;
  }

  String _style(String text, String code) =>
      color ? '\x1B[${code}m$text\x1B[0m' : text;

  String bold(String text) => _style(text, '1');
  String dim(String text) => _style(text, '2');
  String red(String text) => _style(text, '31');
  String green(String text) => _style(text, '32');
  String yellow(String text) => _style(text, '33');
  String cyan(String text) => _style(text, '36');

  static const _palette = ['36', '35', '34', '33', '32', '96', '95', '94'];

  /// [text] in one of several colors, picked by [index], to tell packages
  /// apart.
  String accent(String text, int index) =>
      _style(text, _palette[index % _palette.length]);
}
