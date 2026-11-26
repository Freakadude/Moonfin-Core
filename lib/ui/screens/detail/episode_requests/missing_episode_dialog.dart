import 'package:flutter/material.dart';
import 'package:moonfin_design/moonfin_design.dart';

import '../../../../data/models/sonarr_episode.dart';
import '../../../../util/focus/key_event_utils.dart';
import '../../../widgets/floating_notification.dart';
import '../../../widgets/overlay_sheet.dart';
import 'sonarr_season_controller.dart';

/// English only for now: this is a personal build of the feature.
abstract final class EpisodeRequestText {
  static const requestEpisode = 'Request episode';
  static String requestAllMissing(int count) => 'Request all $count missing';
  static const close = 'Close';
  static const checking = 'Checking Sonarr…';
  static const checkingBody =
      'Sonarr is rescanning its files first. This takes a few seconds.';
  static const requested = 'Requested';
  static const notRequested = 'Not requested';
  static const failedTitle = "Couldn't request";

  static String season(int season, int episode) => 'S$season:E$episode';

  static String state(SonarrEpisode e) {
    if (e.waitingForJellyfin) return 'On disk';
    return switch (e.state) {
      SonarrEpisodeState.missing => 'Missing',
      SonarrEpisodeState.requested => 'Requested',
      SonarrEpisodeState.searching => 'Searching…',
      SonarrEpisodeState.downloading =>
        e.progress == null ? 'Downloading' : 'Downloading ${e.progress}%',
      SonarrEpisodeState.importing => 'Importing',
      SonarrEpisodeState.failed => 'Download failed',
      SonarrEpisodeState.notAired =>
        e.airDate == null ? 'Not aired yet' : 'Airs ${date(e.airDate!)}',
      SonarrEpisodeState.available => 'Available',
      SonarrEpisodeState.unknown => 'Unknown',
    };
  }

  /// A longer line for the dialog, saying what the status means.
  static String explain(SonarrEpisode e) {
    if (e.waitingForJellyfin) {
      return 'Sonarr has the file. Jellyfin will show it after its next library scan.';
    }
    return switch (e.state) {
      SonarrEpisodeState.missing => 'Not in your library and not requested.',
      SonarrEpisodeState.requested =>
        "Requested. Sonarr hasn't found a download yet and keeps looking.",
      SonarrEpisodeState.searching => 'Sonarr is searching for it right now.',
      SonarrEpisodeState.downloading => 'Downloading.',
      SonarrEpisodeState.importing =>
        'Downloaded. Sonarr is moving it into your library.',
      SonarrEpisodeState.failed =>
        e.message ?? 'The download failed. Requesting again searches for another release.',
      SonarrEpisodeState.notAired => "This episode hasn't aired yet.",
      _ => '',
    };
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  static String date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

  /// What a finished request did, as a notification title and body.
  static (String, String) result(EpisodeRequestResult r, int asked) {
    if (r.failed) {
      return (failedTitle, r.message ?? 'Something went wrong (${r.error}).');
    }
    if (r.searched > 0) {
      final skipped = asked - r.searched;
      return (
        requested,
        r.searched == 1
            ? 'Sonarr is searching for the episode.'
            : 'Sonarr is searching for ${r.searched} episodes.'
              '${skipped > 0 ? ' $skipped already on their way.' : ''}',
      );
    }
    final outcome = r.outcomes.values.isEmpty ? null : r.outcomes.values.first;
    return (
      notRequested,
      switch (outcome) {
        'alreadyDownloading' => 'Already downloading.',
        'alreadySearching' => 'Sonarr is already searching for it.',
        'alreadyAvailable' => 'Already in your library.',
        'onDiskWaitingForJellyfin' =>
          'Already on disk. Jellyfin will show it after its next library scan.',
        'notAired' => "It hasn't aired yet.",
        _ => 'Nothing needed requesting.',
      },
    );
  }
}

/// Shows a missing episode with what Sonarr knows about it. Returns the Sonarr
/// episode ids the viewer chose to request, or null.
Future<List<int>?> showMissingEpisodeDialog(
  BuildContext context, {
  required SonarrEpisode episode,
  required List<SonarrEpisode> requestable,
}) async {
  final firstFocus = FocusNode(debugLabel: 'MissingEpisodeFirst');
  try {
    return await OverlaySheetController.show<List<int>>(
      context,
      initialFocusNode: firstFocus,
      builder: (sheetContext) => _MissingEpisodeContent(
        episode: episode,
        requestable: requestable,
        firstFocus: firstFocus,
        onClose: (ids) => OverlaySheetController.closeAdaptive<List<int>>(
          sheetContext,
          result: ids,
        ),
      ),
    );
  } finally {
    firstFocus.dispose();
  }
}

/// Runs a request from a rail, with a notification while Sonarr rescans and
/// another with the result.
Future<void> runEpisodeRequest(
  BuildContext context,
  SonarrSeasonController controller,
  List<int> ids,
) async {
  FloatingNotification.show(
    context,
    EpisodeRequestText.checking,
    EpisodeRequestText.checkingBody,
    null,
    icon: Icons.manage_search_rounded,
    duration: const Duration(seconds: 4),
  );
  final result = await controller.request(ids);
  if (!context.mounted) return;
  final (title, body) = EpisodeRequestText.result(result, ids.length);
  FloatingNotification.show(
    context,
    title,
    body,
    null,
    icon: result.failed
        ? Icons.error_outline_rounded
        : Icons.download_rounded,
  );
}

class _MissingEpisodeContent extends StatefulWidget {
  const _MissingEpisodeContent({
    required this.episode,
    required this.requestable,
    required this.firstFocus,
    required this.onClose,
  });

  final SonarrEpisode episode;
  final List<SonarrEpisode> requestable;
  final FocusNode firstFocus;
  final ValueChanged<List<int>?> onClose;

  @override
  State<_MissingEpisodeContent> createState() => _MissingEpisodeContentState();
}

class _MissingEpisodeContentState extends State<_MissingEpisodeContent> {
  final _allFocus = FocusNode(debugLabel: 'MissingEpisodeAll');
  final _closeFocus = FocusNode(debugLabel: 'MissingEpisodeClose');

  @override
  void dispose() {
    _allFocus.dispose();
    _closeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.episode;
    final canRequest = e.canRequest;
    final others = widget.requestable.length;
    final showAll = others > 1;
    final glass = AppColorScheme.isGlass;
    final muted = AppColorScheme.onSurface.withValues(alpha: 0.7);

    // The first button on the row takes the initial focus, whichever it is.
    final buttons = <(String, FocusNode, VoidCallback)>[
      if (canRequest)
        (EpisodeRequestText.requestEpisode, widget.firstFocus, () => widget.onClose([e.id])),
      if (showAll)
        (
          EpisodeRequestText.requestAllMissing(others),
          canRequest ? _allFocus : widget.firstFocus,
          () => widget.onClose([for (final r in widget.requestable) r.id]),
        ),
      (
        EpisodeRequestText.close,
        canRequest || showAll ? _closeFocus : widget.firstFocus,
        () => widget.onClose(null),
      ),
    ];

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: glass ? const Color(0xD90E1117) : AppColorScheme.surface,
          borderRadius: AppRadius.circular(glass ? 20 : 16),
          border: glass
              ? const Border.fromBorderSide(
                  BorderSide(color: Color(0x33FFFFFF), width: 1),
                )
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                EpisodeRequestText.season(e.seasonNumber, e.episodeNumber),
                if (e.airDate != null) EpisodeRequestText.date(e.airDate!),
              ].join(' · '),
              style: _text(16, muted),
            ),
            const SizedBox(height: 6),
            Text(
              e.title,
              style: _text(26, AppColorScheme.onSurface, weight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 20, color: AppColorScheme.accent),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '${EpisodeRequestText.state(e)}. ${EpisodeRequestText.explain(e)}',
                    style: _text(17, AppColorScheme.onSurface),
                  ),
                ),
              ],
            ),
            if ((e.overview ?? '').isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                e.overview!,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: _text(16, muted),
              ),
            ],
            const SizedBox(height: 28),
            Wrap(
              spacing: 16,
              runSpacing: 12,
              children: [
                for (final (index, (label, node, onPressed)) in buttons.indexed)
                  _DialogButton(
                    label: label,
                    focusNode: node,
                    autofocus: index == 0,
                    onPressed: onPressed,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static TextStyle _text(double size, Color color, {FontWeight weight = FontWeight.w400}) =>
      TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        decoration: TextDecoration.none,
      );
}

class _DialogButton extends StatefulWidget {
  const _DialogButton({
    required this.label,
    required this.focusNode,
    required this.onPressed,
    this.autofocus = false,
  });

  final String label;
  final FocusNode focusNode;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  State<_DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<_DialogButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (node, event) => handleOneShotSelect(event, widget.onPressed),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: _focused
                ? AppColorScheme.onSurface
                : AppColorScheme.onSurface.withValues(alpha: 0.1),
            borderRadius: AppRadius.circular(8),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: _focused ? AppColors.black : AppColorScheme.onSurface,
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}
