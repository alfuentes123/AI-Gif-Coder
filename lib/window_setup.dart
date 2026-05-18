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
  await windowManager.setMaximizable(false);
  _AppWindowListener.install();
  await _AppWindowListener.lockNormalSize();
}

class _AppWindowListener with WindowListener {
  _AppWindowListener._();

  static final _AppWindowListener instance = _AppWindowListener._();
  static bool _installed = false;
  bool _maximized = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    windowManager.addListener(instance);
  }

  static Future<void> lockNormalSize() => instance._lockNormalSize();

  Future<void> _lockNormalSize() async {
    await windowManager.setMinimumSize(kAppWindowSize);
    await windowManager.setMaximumSize(kAppWindowSize);
    if (!_maximized) {
      await windowManager.setSize(kAppWindowSize);
    }
  }

  Future<void> _unlockSize() async {
    await windowManager.setMinimumSize(const Size(320, 480));
    await windowManager.setMaximumSize(const Size(10000, 10000));
  }

  @override
  void onWindowMaximize() {
    _maximized = true;
    _unlockSize();
  }

  @override
  void onWindowUnmaximize() {
    _maximized = false;
    _lockNormalSize();
  }

  @override
  void onWindowRestore() {
    if (!_maximized) _lockNormalSize();
  }
}
