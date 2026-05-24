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
  _AppWindowListener.install();
  await windowManager.setSize(kAppWindowSize);
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

  static Future<void> lockNormalSize() => instance._applyConstraints();

  Future<void> _applyConstraints() async {
    await windowManager.setMinimumSize(Size(kAppWindowSize.width, kAppWindowSize.height));
    await windowManager.setMaximumSize(Size(kAppWindowSize.width, 10000));
  }

  @override
  void onWindowMaximize() {
    _maximized = true;
    _applyConstraints();
  }

  @override
  void onWindowUnmaximize() {
    _maximized = false;
    _applyConstraints();
  }

  @override
  void onWindowRestore() {
    if (!_maximized) _applyConstraints();
  }
}
