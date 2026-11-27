import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/services/app_update_service.dart';
import '../../l10n/app_localizations.dart';
import '../../util/apk_installer.dart';
import '../../util/platform_detection.dart';
import 'track_selector_dialog.dart';

/// Checks for an update and shows the dialog or an appropriate snackbar.
Future<void> checkAndShowUpdateResult(BuildContext context) async {
  final result =
      await GetIt.instance<AppUpdateService>().checkForUpdateNowDetailed();
  if (!context.mounted) return;

  final update = result.update;
  if (update != null) {
    await showAppUpdateDialog(context, update);
    return;
  }

  final l10n = AppLocalizations.of(context);
  final message = switch (result.status) {
    DesktopUpdateCheckStatus.upToDate => l10n.youAreUpToDate,
    DesktopUpdateCheckStatus.checkFailed => l10n.couldNotCheckForUpdates,
    DesktopUpdateCheckStatus.unsupportedPlatform => l10n.updateChecksNotSupported,
    DesktopUpdateCheckStatus.managedByStore => l10n.updateChecksNotSupported,
    DesktopUpdateCheckStatus.disabledByPreference => l10n.updateNotificationsDisabled,
    DesktopUpdateCheckStatus.rateLimited => l10n.pleaseWaitBeforeChecking,
    DesktopUpdateCheckStatus.alreadyNotified => l10n.latestUpdateAlreadyShown,
    DesktopUpdateCheckStatus.updateAvailable => l10n.updateAvailable,
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
  );
}

Future<void> showAppUpdateDialog(
  BuildContext context,
  DesktopUpdateInfo update,
) async {
  final l10n = AppLocalizations.of(context);

  final choice = await showStyledPlayerDialog<String>(
    context,
    title: l10n.updateAvailableTitle(update.version),
    showCancel: true,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The sideloaded Android build installs its own update.
        if (_canSelfInstall(update))
          const _UpdateOption(
            icon: Icons.system_update_rounded,
            label: 'Install update',
            value: 'install',
          )
        else if (!PlatformDetection.isTV)
          _UpdateOption(
            icon: Icons.download_rounded,
            label: l10n.download,
            value: 'download',
          ),
        // A TV has no browser to open the notes in.
        if (!PlatformDetection.isTV)
          _UpdateOption(
            icon: Icons.article_outlined,
            label: l10n.readReleaseNotes,
            value: 'notes',
          ),
      ],
    ),
  );

  if (choice == null || !context.mounted) return;

  if (choice == 'install') {
    await _installAndroidUpdate(context, update);
    return;
  }

  if (choice == 'download' &&
      Platform.isWindows &&
      update.downloadUri.isScheme('https')) {
    await _downloadAndRun(
      context,
      update,
      fileName: 'moonfin_updater.exe',
      run: (file) async {
        await Process.start(file.path, [], mode: ProcessStartMode.detached);
        exit(0);
      },
    );
    return;
  }

  final uri =
      choice == 'notes' ? Uri.parse(update.releaseNotesUrl) : update.downloadUri;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

bool _canSelfInstall(DesktopUpdateInfo update) =>
    ApkInstaller.isSupported &&
    update.downloadUri.isScheme('https') &&
    update.downloadUri.path.toLowerCase().endsWith('.apk');

/// Downloads the new APK and hands it to Android, which asks for one press of
/// Install. Moonfin has to be allowed to install apps first, once.
Future<void> _installAndroidUpdate(
  BuildContext context,
  DesktopUpdateInfo update,
) async {
  if (!await ApkInstaller.canInstall()) {
    if (!context.mounted) return;
    final open = await showStyledPlayerDialog<String>(
      context,
      title: 'Allow Moonfin to install updates',
      showCancel: true,
      builder: (ctx) => const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              'Android needs your permission once. In the settings that open, '
              'allow Moonfin to install unknown apps, then come back and choose '
              'Install update again.',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
          ),
          _UpdateOption(
            icon: Icons.settings_rounded,
            label: 'Open settings',
            value: 'settings',
          ),
        ],
      ),
    );
    if (open == 'settings') await ApkInstaller.openInstallSettings();
    return;
  }
  if (!context.mounted) return;
  await _downloadAndRun(
    context,
    update,
    fileName: 'moonfin_update.apk',
    closeWhenDone: true,
    run: ApkInstaller.install,
  );
}

/// Downloads the update with a progress dialog, then hands the file to [run].
Future<void> _downloadAndRun(
  BuildContext context,
  DesktopUpdateInfo update, {
  required String fileName,
  required Future<void> Function(File file) run,
  bool closeWhenDone = false,
}) async {
  final l10n = AppLocalizations.of(context);
  final valueNotifier = ValueNotifier<double>(0.0);
  final errorNotifier = ValueNotifier<String?>(null);
  BuildContext? progressContext;

  showStyledPlayerDialog<void>(
    context,
    title: l10n.updating,
    barrierDismissible: false,
    builder: (dialogContext) {
      progressContext = dialogContext;
      return _progressBody(dialogContext, l10n, valueNotifier, errorNotifier);
    },
  );

  try {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}${Platform.pathSeparator}$fileName');
    if (await file.exists()) {
      await file.delete();
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client.getUrl(update.downloadUri);
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception('Server returned status code ${response.statusCode}');
      }

      final contentLength = response.contentLength;
      var downloaded = 0;
      final sink = file.openWrite();

      await for (final chunk in response) {
        sink.add(chunk);
        downloaded += chunk.length;
        if (contentLength > 0) {
          valueNotifier.value = downloaded / contentLength;
        }
      }
      await sink.flush();
      await sink.close();
    } finally {
      client.close();
    }

    await run(file);
    final dialog = progressContext;
    if (closeWhenDone && dialog != null && dialog.mounted) {
      Navigator.of(dialog).pop();
    }
  } catch (e) {
    debugPrint('In-app update failed: $e');
    errorNotifier.value = l10n.updateDownloadFailed;
  }
}

Widget _progressBody(
  BuildContext dialogContext,
  AppLocalizations l10n,
  ValueNotifier<double> valueNotifier,
  ValueNotifier<String?> errorNotifier,
) =>
    PopScope(
      canPop: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: AnimatedBuilder(
          animation: Listenable.merge([valueNotifier, errorNotifier]),
          builder: (context, child) {
            final error = errorNotifier.value;
            if (error != null) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    error,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(
                        l10n.close,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ],
              );
            }

            final progress = valueNotifier.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                ),
                const SizedBox(height: 12),
                Text(
                  '${(progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
              ],
            );
          },
        ),
      ),
    );

class _UpdateOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _UpdateOption({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 22, color: Colors.white70),
            const SizedBox(width: 16),
            Text(
              label,
              style: const TextStyle(fontSize: 15, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
