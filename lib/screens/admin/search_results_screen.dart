import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/search_data.dart';
import '../../providers/search_providers.dart';
import '../../widgets/admin/search_filter_chips.dart';
import '../../widgets/admin/search_result_tile.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../core/theme/theme_context.dart';

/// Route arguments for [SearchResultsScreen] — the query/filter the
/// person had active on [GlobalSearchScreen] when they asked to see the
/// full results.
class SearchResultsArgs {
  final String query;
  final SearchResultType? type;

  const SearchResultsArgs({this.query = '', this.type});
}

/// Dedicated, full-page "all results" screen for Global Search. Reached
/// from [GlobalSearchScreen] once a query has results — offers a larger
/// list/grid view plus the same type filter, backed by the exact same
/// [SearchRepository] the inline search already uses (via
/// [searchRepositoryProvider]) so results are always identical between
/// the two, just presented differently.
class SearchResultsScreen extends ConsumerStatefulWidget {
  final String initialQuery;
  final SearchResultType? initialType;

  const SearchResultsScreen(
      {super.key, this.initialQuery = '', this.initialType});

  @override
  ConsumerState<SearchResultsScreen> createState() =>
      _SearchResultsScreenState();
}

class _SearchResultsScreenState extends ConsumerState<SearchResultsScreen> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);
  SearchResultType? _filter;
  String _query = '';

  List<SearchResultItem>? _results;
  bool _loading = true;
  bool _gridView = false;

  @override
  void initState() {
    super.initState();
    _filter = widget.initialType;
    _query = widget.initialQuery;
    _runSearch();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    setState(() => _loading = true);
    final repo = ref.read(searchRepositoryProvider);
    final results = await repo.search(query: _query, type: _filter);
    if (!mounted) return;
    setState(() {
      _results = results;
      _loading = false;
    });
  }

  void _selectFilter(SearchResultType? type) {
    setState(() => _filter = type);
    _runSearch();
  }

  void _submit(String value) {
    final trimmed = value.trim();
    setState(() => _query = trimmed);
    if (trimmed.isNotEmpty) {
      ref.read(recentSearchesProvider.notifier).add(trimmed);
    }
    _runSearch();
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
    final items = _results ?? const [];

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Search Results',
        actions: [
          IconButton(
            icon: Icon(
                _gridView ? Icons.view_list_rounded : Icons.grid_view_rounded),
            tooltip: _gridView ? 'List view' : 'Grid view',
            onPressed: () => setState(() => _gridView = !_gridView),
          ),
          SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
            child: Container(
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
                      controller: _controller,
                      onSubmitted: _submit,
                      textInputAction: TextInputAction.search,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color:
                              (Theme.of(context).brightness == Brightness.dark
                                  ? AppColors.textOnDark
                                  : AppColors.text)),
                      decoration: InputDecoration(
                        hintText: 'Refine your search…',
                        hintStyle: TextStyle(
                            fontSize: 13,
                            color:
                                (Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : AppColors.subtitle)),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (_controller.text.isNotEmpty)
                    InkWell(
                      onTap: () {
                        _controller.clear();
                        _submit('');
                      },
                      borderRadius: BorderRadius.circular(100),
                      child: Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded,
                            size: 18,
                            color:
                                (Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.subtitleOnDark
                                    : AppColors.subtitle)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: AppSpacing.sm),
          SearchFilterChips(selected: _filter, onSelected: _selectFilter),
          SizedBox(height: AppSpacing.sm),
          if (!_loading)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${items.length} result${items.length == 1 ? '' : 's'}${_query.isNotEmpty ? ' for "$_query"' : ''}',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: (Theme.of(context).brightness == Brightness.dark
                          ? AppColors.subtitleOnDark
                          : AppColors.subtitle)),
                ),
              ),
            ),
          SizedBox(height: AppSpacing.sm),
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(color: AppColors.primary))
                : items.isEmpty
                    ? Padding(
                        padding: EdgeInsets.all(AppSpacing.lg),
                        child: EmptyStateCard(
                          icon: Icons.search_off_rounded,
                          message:
                              'No results found — try a different search term or filter',
                        ),
                      )
                    : (_gridView
                        ? _ResultsGrid(items: items, onTap: _openResult)
                        : _ResultsList(items: items, onTap: _openResult)),
          ),
        ],
      ),
    );
  }
}

class _ResultsList extends StatelessWidget {
  final List<SearchResultItem> items;
  final ValueChanged<SearchResultItem> onTap;

  const _ResultsList({required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding:
          EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xl),
      itemCount: items.length,
      separatorBuilder: (_, __) => SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) =>
          SearchResultTile(data: items[i], onTap: () => onTap(items[i])),
    );
  }
}

/// Responsive grid of results — column count adapts to available width so
/// the same screen reads well on a phone, a fold-out, or a tablet/desktop
/// window.
class _ResultsGrid extends StatelessWidget {
  final List<SearchResultItem> items;
  final ValueChanged<SearchResultItem> onTap;

  const _ResultsGrid({required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 600
                ? 3
                : 2;
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xl),
          itemCount: items.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: AppSpacing.sm,
            crossAxisSpacing: AppSpacing.sm,
            childAspectRatio: 0.95,
          ),
          itemBuilder: (context, i) =>
              _ResultGridTile(data: items[i], onTap: () => onTap(items[i])),
        );
      },
    );
  }
}

class _ResultGridTile extends StatelessWidget {
  final SearchResultItem data;
  final VoidCallback? onTap;

  const _ResultGridTile({required this.data, this.onTap});

  @override
  Widget build(BuildContext context) {
    final gradient = data.type.gradient;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: context.borderColor),
          boxShadow: [
            BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.06),
                blurRadius: 14,
                offset: const Offset(0, 8)),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: double.infinity,
              height: 56,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: gradient,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(data.type.icon, color: Colors.white, size: 24),
            ),
            SizedBox(height: 10),
            Text(data.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text))),
            SizedBox(height: 2),
            Text(data.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle))),
            const Spacer(),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: gradient.first.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(data.type.label,
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: gradient.first)),
            ),
          ],
        ),
      ),
    );
  }
}
