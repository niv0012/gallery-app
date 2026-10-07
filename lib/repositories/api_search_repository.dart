import '../core/network/api_client.dart';
import '../data/search_repository.dart';
import '../models/search_data.dart';

/// Wires the `/search` FastAPI endpoints (`app/api/routes/search.py`) up
/// to [ApiClient] — same one-repository-per-router-group convention as
/// [LegalRepository]/[ApiAlbumRepository].
class ApiSearchRepository implements SearchRepository {
  final ApiClient _apiClient;

  ApiSearchRepository({required ApiClient apiClient}) : _apiClient = apiClient;

  /// GET /search?q=...&type=...
  @override
  Future<List<SearchResultItem>> search(
      {String query = '', SearchResultType? type}) async {
    final params = <String, String>{'q': query};
    if (type != null) params['type'] = type.name;
    final path = '/search?${Uri(queryParameters: params).query}';

    final json = await _apiClient.get(path);
    return (json as List).cast<Map<String, dynamic>>().map(_fromJson).toList();
  }

  /// GET /search/suggestions
  @override
  Future<List<String>> fetchSuggestions() async {
    final json = await _apiClient.get('/search/suggestions');
    return (json as List).cast<String>();
  }

  SearchResultItem _fromJson(Map<String, dynamic> json) {
    return SearchResultItem(
      id: json['id'] as String,
      type: SearchResultType.values.byName(json['type'] as String),
      title: json['title'] as String,
      subtitle: json['subtitle'] as String,
    );
  }
}
