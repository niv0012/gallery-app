import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/search_repository.dart';
import '../repositories/api_search_repository.dart';
import 'auth_providers.dart' show apiClientProvider;

/// Global Search wired up to the real backend.
final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  return ApiSearchRepository(apiClient: ref.watch(apiClientProvider));
});

/// In-memory "Recent Searches" history for the current session — newest
/// first, capped at 8, de-duplicated. Kept separate from the dashboard
/// snapshot since it's UI/session state rather than studio data.
final recentSearchesProvider =
    NotifierProvider<RecentSearchesNotifier, List<String>>(
        RecentSearchesNotifier.new);

class RecentSearchesNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void add(String term) {
    final trimmed = term.trim();
    if (trimmed.isEmpty) return;
    final next = [
      trimmed,
      ...state.where((t) => t.toLowerCase() != trimmed.toLowerCase())
    ];
    state = next.take(8).toList();
  }

  void remove(String term) {
    state = state.where((t) => t != term).toList();
  }

  void clear() {
    state = const [];
  }
}
