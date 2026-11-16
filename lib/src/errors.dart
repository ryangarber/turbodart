/// An error to report to the user, without a stack trace.
class TurbodartException implements Exception {
  TurbodartException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A problem with a pubspec or its `turbodart` section.
class ConfigException extends TurbodartException {
  ConfigException(super.message);
}

/// A command line that can't be acted on.
class UsageException extends TurbodartException {
  UsageException(super.message);
}
