import 'package:flutter/foundation.dart';

/// Release builds must not expose pilot server-URL override (C-1).
bool get hiddenServerSettingsEnabled => !kReleaseMode;