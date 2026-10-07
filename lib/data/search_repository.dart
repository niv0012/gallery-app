import '../models/search_data.dart';

/// Contract Global Search is coded against — same pattern as
/// [AdminDashboardRepository]: the UI never touches the dummy content
/// directly, only this interface, so a real search backend can replace
/// [InMemorySearchRepository] later with zero screen changes.
abstract class SearchRepository {
  /// Returns every indexed item, optionally filtered by [type] and/or
  /// matched (case-insensitive) against [query]. Starts empty — real
  /// results only appear once Albums/Folders/Photos actually exist.
  Future<List<SearchResultItem>> search(
      {String query = '', SearchResultType? type});

  /// Short list of suggested terms shown while the search field is
  /// empty or partially typed. Starts empty — no canned suggestions.
  Future<List<String>> fetchSuggestions();
}

