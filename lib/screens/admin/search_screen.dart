import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/search_data.dart';
import '../../providers/search_providers.dart';
import '../../widgets/admin/search_filter_chips.dart';
import '../../widgets/admin/search_result_tile.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import 'search_results_screen.dart';
import '../../core/theme/theme_context.dart';

/// Global Search — searches Albums, Photos, Videos and Folders in one
/// place. Fully self-contained: query + filter live as local state,
/// dummy results come from [SearchRepository], and "Recent Searches"
/// persists for the session via [recentSearchesProvider]. Visually reuses
/// [CustomAppBar], [GlassIconButton] and the same card/border language
/// as the rest of the Admin shell instead of introducing a new style.
class GlobalSearchScreen extends ConsumerStatefulWidget {
  const GlobalSearchScreen({super.key});

  @override
  ConsumerState<GlobalSearchScreen> createState() => _GlobalSearchScreenState();
}

class _GlobalSearchScreenState extends ConsumerState<GlobalSearchScreen> {
  final _controller = TextEditingController();
  SearchResultType? _filter;
  String _query = '';

  List<SearchResultItem>? _results;
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String query) async {
    setState(() {
      _query = query;
      _loading = true;
    });
    final repo = ref.read(searchRepositoryProvider);
    final results = await repo.search(query: query, type: _filter);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  void _submit(String query) {
    if (query.trim().isEmpty) return;
    ref.read(recentSearchesProvider.notifier).add(query.trim());
    _runSearch(query);
  }

  void _selectFilter(SearchResultType? type) {
    setState(() => _filter = type);
    if (_query.isNotEmpty) _runSearch(_query);
  }

  void _openTerm(String term) {
    _controller.text = term;
    _controller.selection =
        TextSelection.fromPosition(TextPosition(offset: term.length));
    _submit(term);
  }

  void _openResult(SearchResultItem item) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Opening "${item.title}"'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: (Theme.of(context).brightness == Brightness.dark
            ? AppColors.textOnDark
            : AppColors.text),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recentSearches = ref.watch(recentSearchesProvider);

    return Scaffold(
      appBar: CustomAppBar(
        centerTitle: false,
        titleWidget: _SearchField(
          controller: _controller,
          onChanged: (v) => setState(() => _query = v),
          onSubmitted: _submit,
          onClear: () {
            _controller.clear();
            setState(() {
              _query = '';
              _results = null;
            });
          },
        ),
        actions: [
          if (_query.trim().isNotEmpty)
            IconButton(
              icon: Icon(Icons.open_in_full_rounded),
              tooltip: 'View full results',
              onPressed: () => Navigator.pushNamed(
                context,
                AppRoutes.searchResults,
                arguments: SearchResultsArgs(query: _query, type: _filter),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(height: AppSpacing.sm),
          SearchFilterChips(selected: _filter, onSelected: _selectFilter),
          SizedBox(height: AppSpacing.sm),
          Expanded(
            child: _query.trim().isEmpty
                ? _SearchLanding(
                    recentSearches: recentSearches,
                    onTapTerm: _openTerm,
                    onRemoveTerm: (t) =>
                        ref.read(recentSearchesProvider.notifier).remove(t),
                    onClearAll: () =>
                        ref.read(recentSearchesProvider.notifier).clear(),
                  )
                : _SearchResultsList(
                    loading: _loading,
                    results: _results,
                    onResultTap: _openResult,
                  ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      padding: EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded,
              size: 20,
              color: (Theme.of(context).brightness == Brightness.dark
                  ? AppColors.subtitleOnDark
                  : AppColors.subtitle)),
          SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: (Theme.of(context).brightness == Brightness.dark
                      ? AppColors.textOnDark
                      : AppColors.text)),
              decoration: InputDecoration(
                hintText: 'Search albums, photos, videos, folders…',
                hintStyle: TextStyle(
                    fontSize: 13,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle)),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return SizedBox.shrink();
              return InkWell(
                onTap: onClear,
                borderRadius: BorderRadius.circular(100),
                child: Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded,
                      size: 18,
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle)),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SearchLanding extends StatelessWidget {
  final List<String> recentSearches;
  final ValueChanged<String> onTapTerm;
  final ValueChanged<String> onRemoveTerm;
  final VoidCallback onClearAll;

  const _SearchLanding({
    required this.recentSearches,
    required this.onTapTerm,
    required this.onRemoveTerm,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xl),
      children: [
        if (recentSearches.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text('Recent Searches',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text))),
              ),
              InkWell(
                onTap: onClearAll,
                child: Text('Clear all',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primary)),
              ),
            ],
          ),
          SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: recentSearches.map((term) {
              return InputChip(
                label: Text(term,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.textOnDark
                            : AppColors.text))),
                avatar: Icon(Icons.history_rounded,
                    size: 16,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle)),
                backgroundColor: context.surfaceColor,
                side: BorderSide(color: context.borderColor),
                onPressed: () => onTapTerm(term),
                onDeleted: () => onRemoveTerm(term),
                deleteIconColor:
                    (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle),
              );
            }).toList(),
          ),
          SizedBox(height: AppSpacing.xl),
        ],
        Text('Search Suggestions',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: (Theme.of(context).brightness == Brightness.dark
                    ? AppColors.textOnDark
                    : AppColors.text))),
        SizedBox(height: AppSpacing.sm),
        Consumer(
          builder: (context, ref, _) {
            return FutureBuilder<List<String>>(
              future: ref.read(searchRepositoryProvider).fetchSuggestions(),
              builder: (context, snapshot) {
                final suggestions = snapshot.data ?? const [];
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Padding(
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                    child: Center(
                        child: CircularProgressIndicator(
                            color: AppColors.primary, strokeWidth: 2)),
                  );
                }
                return Column(
                  children: suggestions.map((s) {
                    return InkWell(
                      onTap: () => onTapTerm(s),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 10),
                        child: Row(
                          children: [
                            Icon(Icons.north_west_rounded,
                                size: 15,
                                color: (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : AppColors.subtitle)),
                            SizedBox(width: 10),
                            Expanded(
                                child: Text(s,
                                    style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w500,
                                        color: (Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? AppColors.textOnDark
                                            : AppColors.text)))),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _SearchResultsList extends StatelessWidget {
  final bool loading;
  final List<SearchResultItem>? results;
  final ValueChanged<SearchResultItem> onResultTap;

  const _SearchResultsList(
      {required this.loading,
      required this.results,
      required this.onResultTap});

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(child: CircularProgressIndicator(color: AppColors.primary));
    }
    final items = results ?? const [];
    if (items.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: EmptyStateCard(
          icon: Icons.search_off_rounded,
          message: 'No results found — try a different search term or filter',
        ),
      );
    }
    return ListView.separated(
      padding:
          EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xl),
      itemCount: items.length,
      separatorBuilder: (_, __) => SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) =>
          SearchResultTile(data: items[i], onTap: () => onResultTap(items[i])),
    );
  }
}
