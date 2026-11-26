import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get_it/get_it.dart';

import '../../../../data/models/aggregated_item.dart';
import '../../../../data/models/sonarr_episode.dart';
import '../../../../data/repositories/episode_request_repository.dart';
import '../../../../data/services/plugin_sync_service.dart';

/// The server id placeholder episodes carry, so nothing mistakes them for a
/// Jellyfin item.
const String kSonarrPlaceholderServerId = 'sonarr';

/// Whether this item is a missing episode drawn from Sonarr rather than one
/// from the library.
bool isSonarrPlaceholder(AggregatedItem item) =>
    item.serverId == kSonarrPlaceholderServerId;

/// The Sonarr episode id a placeholder stands for.
int? sonarrEpisodeIdOf(AggregatedItem item) =>
    item.rawData['SonarrEpisodeId'] as int?;

/// Keeps one season's Sonarr status for an episode rail, and asks again every
/// few seconds while something in it is searching or downloading.
class SonarrSeasonController extends ChangeNotifier {
  SonarrSeasonController({EpisodeRequestRepository? repository})
    : _repository = repository ?? GetIt.instance<EpisodeRequestRepository>();

  static const _pollEvery = Duration(seconds: 10);

  /// Whether the signed-in user may use episode requests on this server.
  static bool get available {
    final getIt = GetIt.instance;
    return getIt.isRegistered<PluginSyncService>() &&
        getIt.isRegistered<EpisodeRequestRepository>() &&
        getIt<PluginSyncService>().episodeRequestsAvailable;
  }

  final EpisodeRequestRepository _repository;

  String? _seriesId;
  int? _season;
  SonarrSeason? _data;
  Timer? _poll;
  bool _requesting = false;
  bool _disposed = false;
  int _generation = 0;

  String? get seriesId => _seriesId;
  bool get requesting => _requesting;

  List<SonarrEpisode> get _episodes => _data?.episodes ?? const [];

  /// The season's episodes Jellyfin doesn't have, in episode order.
  List<SonarrEpisode> get missingFromLibrary =>
      _episodes.where((e) => !e.inLibrary).toList()
        ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));

  /// The ones a request can still do something for.
  List<SonarrEpisode> get requestable =>
      missingFromLibrary.where((e) => e.canRequest).toList();

  SonarrEpisode? byId(int id) {
    for (final e in _episodes) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Points the controller at a season. Nothing happens when it already
  /// shows that one. Safe to call from build: listeners hear about it later.
  void show(String seriesId, int season) {
    if (_seriesId == seriesId && _season == season) return;
    _seriesId = seriesId;
    _season = season;
    _data = null;
    _poll?.cancel();
    unawaited(_load());
  }

  /// Asks Sonarr again now.
  Future<void> refresh() => _load();

  Future<void> _load() async {
    final seriesId = _seriesId;
    final season = _season;
    if (seriesId == null || season == null) return;
    final generation = ++_generation;
    final data = await _repository.season(seriesId, season);
    if (_disposed || generation != _generation) return;
    _data = data;
    notifyListeners();
    _schedulePoll();
  }

  void _schedulePoll() {
    _poll?.cancel();
    if (_episodes.any((e) => e.state.isActive)) {
      _poll = Timer(_pollEvery, () => unawaited(_load()));
    }
  }

  /// Rescans the series in Sonarr and searches the episodes still missing.
  Future<EpisodeRequestResult> request(List<int> sonarrEpisodeIds) async {
    final seriesId = _seriesId;
    if (seriesId == null || sonarrEpisodeIds.isEmpty) {
      return const EpisodeRequestResult(error: 'noEpisodes');
    }
    _requesting = true;
    notifyListeners();
    try {
      return await _repository.request(seriesId, sonarrEpisodeIds);
    } finally {
      _requesting = false;
      if (!_disposed) {
        notifyListeners();
        await _load();
      }
    }
  }

  /// A card for an episode Jellyfin doesn't have. It looks like a virtual
  /// item to the rest of the app, so playback and Next Up leave it alone.
  AggregatedItem placeholderFor(SonarrEpisode episode) => AggregatedItem(
    id: 'sonarr-${episode.id}',
    serverId: kSonarrPlaceholderServerId,
    rawData: {
      'Id': 'sonarr-${episode.id}',
      'Name': episode.title,
      'Type': 'Episode',
      'IndexNumber': episode.episodeNumber,
      'ParentIndexNumber': episode.seasonNumber,
      'SeriesId': _seriesId,
      'Overview': episode.overview,
      'PremiereDate': episode.airDate?.toUtc().toIso8601String(),
      'IsVirtualItem': true,
      'LocationType': 'Virtual',
      'SonarrEpisodeId': episode.id,
    },
  );

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    super.dispose();
  }
}
