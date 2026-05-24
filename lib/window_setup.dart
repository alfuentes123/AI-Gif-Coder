import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// Default portrait size when the window is not maximized.
const Size kAppWindowSize = Size(540, 720);

bool get isDesktopPlatform =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

Future<void> configureAppWindow() async {
  if (!isDesktopPlatform) return;

  await windowManager.ensureInitialized();
  await windowManager.setMaximizable(true);
  await windowManager.setSize(kAppWindowSize);
}
