import 'package:dio/dio.dart';
import 'package:server_core/server_core.dart';

import '../models/sonarr_episode.dart';
import '../services/moonbase_endpoint.dart';

/// Reads a season's episodes from Sonarr and requests single episodes,
/// through Moonbase's Sonarr/Episodes routes. Moonbase holds the Sonarr key
/// and only lets Jellyfin admins in.
class EpisodeRequestRepository {
  EpisodeRequestRepository(this._client);

  final MediaServerClient _client;

  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      // A request waits for Sonarr to rescan the series, up to a minute.
      receiveTimeout: const Duration(seconds: 90),
    ),
  );

  /// The season as Sonarr has it, or null when Moonbase couldn't answer.
  Future<SonarrSeason?> season(String seriesId, int seasonNumber) async {
    final ep = await moonbaseEndpoint(_client, _dio);
    if (ep == null) return null;
    try {
      final response = await _dio.get<dynamic>(
        '${ep.base}/Moonfin/Sonarr/Episodes',
        queryParameters: {'seriesId': seriesId, 'season': '$seasonNumber'},
        options: Options(headers: ep.headers),
      );
      final data = response.data;
      return data is Map<String, dynamic> ? SonarrSeason.fromJson(data) : null;
    } on DioException {
      return null;
    }
  }

  /// Rescans the series in Sonarr, then searches the episodes that are still
  /// missing. Never throws: a failure comes back with its error set.
  Future<EpisodeRequestResult> request(
    String seriesId,
    List<int> sonarrEpisodeIds,
  ) async {
    final ep = await moonbaseEndpoint(_client, _dio);
    if (ep == null) {
      return const EpisodeRequestResult(
        error: 'noServer',
        message: "Moonbase couldn't be reached.",
      );
    }
    try {
      final response = await _dio.post<dynamic>(
        '${ep.base}/Moonfin/Sonarr/Episodes/Request',
        data: {'seriesId': seriesId, 'sonarrEpisodeIds': sonarrEpisodeIds},
        options: Options(headers: ep.headers),
      );
      final data = response.data;
      return data is Map<String, dynamic>
          ? EpisodeRequestResult.fromJson(data)
          : const EpisodeRequestResult(
              error: 'unreadable',
              message: "Moonbase's answer couldn't be read.",
            );
    } on DioException catch (e) {
      final data = e.response?.data;
      if (data is Map) {
        return EpisodeRequestResult(
          error: data['error'] as String? ?? 'failed',
          message: data['message'] as String?,
        );
      }
      return EpisodeRequestResult(
        error: 'failed',
        message: e.response == null
            ? "Moonbase couldn't be reached."
            : 'The request failed (${e.response?.statusCode}).',
      );
    }
  }

  void dispose() => _dio.close();
}
