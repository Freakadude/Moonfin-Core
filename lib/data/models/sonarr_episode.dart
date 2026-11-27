/// Where one episode stands in Sonarr, as Moonbase's Sonarr/Episodes route
/// reports it.
enum SonarrEpisodeState {
  available,
  downloading,
  importing,
  failed,
  requested,
  missing,
  notAired,
  searching,
  unknown;

  static SonarrEpisodeState parse(Object? value) => switch (value) {
    'available' => available,
    'downloading' => downloading,
    'importing' => importing,
    'failed' => failed,
    'requested' => requested,
    'missing' => missing,
    'notAired' => notAired,
    'searching' => searching,
    _ => unknown,
  };

  /// Sonarr is working on it, so the status is worth asking for again soon.
  bool get isActive =>
      this == downloading || this == importing || this == searching;
}

/// One episode of a season as Sonarr lists it.
class SonarrEpisode {
  const SonarrEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    required this.title,
    required this.state,
    this.overview,
    this.airDate,
    this.monitored = false,
    this.hasFile = false,
    this.jellyfinId,
    this.progress,
    this.message,
    this.imageUrl,
  });

  /// Sonarr's own episode id, which a request names.
  final int id;
  final int seasonNumber;
  final int episodeNumber;
  final String title;
  final String? overview;
  final DateTime? airDate;
  final bool monitored;
  final bool hasFile;
  final SonarrEpisodeState state;

  /// The Jellyfin episode this is, when the library has it.
  final String? jellyfinId;

  /// Download progress, 0 to 100, while it's in the queue.
  final int? progress;

  /// Why a download is stuck, when Sonarr says.
  final String? message;

  /// The episode still from TVDB, for an episode Jellyfin has no artwork for.
  final String? imageUrl;

  /// In Jellyfin, so it has a card of its own already.
  bool get inLibrary => jellyfinId != null;

  /// On disk according to Sonarr, but Jellyfin hasn't picked it up yet.
  bool get waitingForJellyfin => hasFile && !inLibrary;

  /// Something a request can still help with. An episode only Sonarr thinks
  /// is on disk counts too: its file may have been deleted, and a request
  /// rescans Sonarr first, so it searches only when the file is really gone.
  bool get canRequest =>
      waitingForJellyfin ||
      (!hasFile &&
          (state == SonarrEpisodeState.missing ||
              state == SonarrEpisodeState.requested ||
              state == SonarrEpisodeState.failed));

  static SonarrEpisode? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final season = raw['seasonNumber'];
    final number = raw['episodeNumber'];
    if (id is! int || season is! int || number is! int) return null;
    final air = raw['airDateUtc'];
    final progress = raw['progress'];
    return SonarrEpisode(
      id: id,
      seasonNumber: season,
      episodeNumber: number,
      title: raw['title'] as String? ?? '',
      overview: raw['overview'] as String?,
      airDate: air is String ? DateTime.tryParse(air)?.toLocal() : null,
      monitored: raw['monitored'] == true,
      hasFile: raw['hasFile'] == true,
      state: SonarrEpisodeState.parse(raw['state']),
      jellyfinId: raw['jellyfinId'] as String?,
      progress: progress is num ? progress.round() : null,
      message: raw['message'] as String?,
      imageUrl: raw['imageUrl'] as String?,
    );
  }
}

/// A season as Sonarr has it.
class SonarrSeason {
  const SonarrSeason({
    required this.inSonarr,
    required this.episodes,
    this.seriesMonitored = true,
  });

  final bool inSonarr;
  final bool seriesMonitored;
  final List<SonarrEpisode> episodes;

  static SonarrSeason fromJson(Map<String, dynamic> json) => SonarrSeason(
    inSonarr: json['inSonarr'] == true,
    seriesMonitored: json['seriesMonitored'] != false,
    episodes: [
      for (final raw in (json['episodes'] as List?) ?? const [])
        ?SonarrEpisode.fromJson(raw),
    ],
  );
}

/// What a request did for each episode it named.
class EpisodeRequestResult {
  const EpisodeRequestResult({
    this.searched = 0,
    this.outcomes = const {},
    this.error,
    this.message,
  });

  /// How many episodes a search was started for.
  final int searched;

  /// Moonbase's outcome per Sonarr episode id: searching, alreadyAvailable,
  /// onDiskWaitingForJellyfin, alreadyDownloading, alreadySearching, notAired
  /// or episodeNotFound.
  final Map<int, String> outcomes;

  /// Moonbase's error code when the request failed, such as rescanTimeout.
  final String? error;
  final String? message;

  bool get failed => error != null;

  static EpisodeRequestResult fromJson(Map<String, dynamic> json) =>
      EpisodeRequestResult(
        searched: (json['searched'] as num?)?.toInt() ?? 0,
        outcomes: {
          for (final raw in (json['results'] as List?) ?? const [])
            if (raw is Map && raw['id'] is int && raw['outcome'] is String)
              raw['id'] as int: raw['outcome'] as String,
        },
      );
}
