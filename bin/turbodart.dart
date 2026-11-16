import 'dart:io';

import 'package:turbodart/turbodart.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runTurbodart(arguments);
}
