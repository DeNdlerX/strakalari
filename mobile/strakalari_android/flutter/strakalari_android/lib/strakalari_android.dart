library strakalari_android;

import 'package:flet/flet.dart';

/// Flet registers every bundled extension through this class. Nothing to
/// add on the Flutter side: the Android code is reached from Python
/// through pyjnius (see android/).
class Extension extends FletExtension {}
