import 'dart:io';

import 'package:flutter/services.dart';

import 'app_distribution.dart';

/// Installs a downloaded APK of this app through Android's package installer
/// (AppUpdateInstaller.kt), for the sideloaded APK build that no store updates.
abstract final class ApkInstaller {
  static const _channel = MethodChannel('org.moonfin.androidtv/app_update');

  /// Whether this build can update itself in place.
  static bool get isSupported =>
      Platform.isAndroid && AppDistribution.channel == DistributionChannel.apk;

  /// Whether the viewer has allowed Moonfin to install apps.
  static Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens the setting that lets Moonfin install apps.
  static Future<void> openInstallSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } catch (_) {}
  }

  /// Hands [apk] to Android, which shows its install confirmation.
  static Future<void> install(File apk) =>
      _channel.invokeMethod<void>('install', {'path': apk.path});
}
