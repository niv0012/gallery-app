import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/media_model.dart';
import '../../core/routes/app_routes.dart';
import '../../providers/media_provider.dart';

import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/loading_widget.dart';
import '../../widgets/common/highlighted_text.dart';
import 'media_grid_screen.dart';
import 'media_details_screen.dart';
import '../../core/theme/theme_context.dart';

class MediaSearchScreen extends ConsumerStatefulWidget {
  final MediaSearchArgs? initialArgs;

  const MediaSearchScreen({super.key, this.initialArgs});

  @override
  ConsumerState<MediaSearchScreen> createState() => _MediaSearchScreenState();
}

class _MediaSearchScreenState extends ConsumerState<MediaSearchScreen>
    with RouteAware {
  final _controller = TextEditingController();

  String _query = '';
  bool _attempted = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final q = _controller.text;
      setState(() => _query = q);
      final c = ref.read(mediaProvider);
      c.setSearchQuery(q);
      setState(() {
        _attempted = true;
      });
    });

    // Deferred: these call notifyListeners() on mediaProvider, and doing
    // that synchronously inside initState() throws "Tried to modify a
    // provider while the widget tree was building". Running it in a
    // post-frame callback lets the current build finish first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyInitialScope();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  /// Same reasoning as [MediaGridScreen._MediaGridScreenState.didPopNext]:
  /// `mediaProvider` is a single shared instance, so a screen further
  /// down the stack needs to re-scope it once whatever was pushed on top
  /// (e.g. Media Details, a filtered grid) is popped back off.
  @override
  void didPopNext() => _applyInitialScope();

  void _applyInitialScope() {
    final args = widget.initialArgs;
    if (args == null) return;
    final c = ref.read(mediaProvider);
    c.setFilterOption(args.favoritesOnly
        ? MediaFilterOption.favorites
        : MediaFilterOption.all);
    c.setAlbum(args.initialAlbumId);
    c.setFolder(args.initialFolderId);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(mediaProvider);
    final results = c.filteredMedia;

    return Scaffold(
      appBar: CustomAppBar(
        title: 'Search Media',
        showBack: true,
        actions: [
          if (_query.isNotEmpty)
            IconButton(
              tooltip: 'Clear',
              icon: Icon(Icons.close_rounded),
              onPressed: () {
                _controller.clear();
                final controller = ref.read(mediaProvider);
                controller.setSearchQuery('');
              },
            )
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: TextField(
              controller: _controller,
              autofocus: true,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              decoration: InputDecoration(
                hintText: 'Search by file name, album, or folder…',
                prefixIcon: Icon(Icons.search_rounded, size: 20),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.close_rounded),
                        onPressed: () {
                          _controller.clear();
                          ref.read(mediaProvider).setSearchQuery('');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _attempted && _query.isNotEmpty
                        ? '${results.length} match(es)'
                        : 'Type to search instantaneously',
                    style: TextStyle(
                        color: (Theme.of(context).brightness == Brightness.dark
                            ? AppColors.subtitleOnDark
                            : AppColors.subtitle),
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5),
                  ),
                ),
                IconButton(
                  tooltip: 'Filters',
                  icon: Icon(Icons.filter_list_rounded),
                  onPressed: () {
                    Navigator.of(context).pushNamed(AppRoutes.mediaFilter);
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: c.isLoading
                ? Center(child: LoadingWidget(message: 'Searching…'))
                : (!_attempted || _query.trim().isEmpty)
                    ? Padding(
                        padding: EdgeInsets.all(AppSpacing.lg),
                        child: EmptyStateCard(
                          icon: Icons.search_rounded,
                          message:
                              'Start typing to search your local Hive media library.',
                        ),
                      )
                    : results.isEmpty
                        ? Center(
                            child: EmptyStateCard(
                              icon: Icons.search_off_rounded,
                              message:
                                  'No media results found. Try another term or filter.',
                            ),
                          )
                        : ListView.separated(
                            padding: EdgeInsets.all(AppSpacing.lg),
                            itemCount: results.length,
                            separatorBuilder: (_, __) =>
                                SizedBox(height: AppSpacing.sm),
                            itemBuilder: (context, i) {
                              final m = results[i];
                              return Material(
                                color: context.surfaceColor,
                                borderRadius:
                                    BorderRadius.circular(AppRadius.lg),
                                borderOnForeground: true,
                                child: InkWell(
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.lg),
                                  onTap: () {
                                    Navigator.of(context).pushNamed(
                                      AppRoutes.mediaDetails,
                                      arguments: MediaDetailsArgs(
                                        mediaId: m.id,
                                        mediaIds: results
                                            .map((x) => x.id)
                                            .toList(growable: false),
                                      ),
                                    );
                                  },
                                  child: Padding(
                                    padding: EdgeInsets.all(AppSpacing.md),
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 52,
                                          height: 52,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                                AppRadius.md),
                                            border: Border.all(
                                                color: context.borderColor),
                                            gradient: LinearGradient(
                                              colors: [
                                                Color(m.gradientArgb.first),
                                                Color(m.gradientArgb[1]),
                                              ],
                                            ),
                                          ),
                                          child: Icon(
                                            m.type == MediaType.photo
                                                ? Icons.image_rounded
                                                : Icons.videocam_rounded,
                                            color: Colors.white,
                                            size: 26,
                                          ),
                                        ),
                                        SizedBox(width: AppSpacing.md),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              HighlightedText(
                                                text: m.fileName,
                                                query: _query,
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: (Theme.of(context)
                                                              .brightness ==
                                                          Brightness.dark
                                                      ? AppColors.textOnDark
                                                      : AppColors.text),
                                                ),
                                              ),
                                              SizedBox(height: 4),
                                              Text(
                                                '${m.albumId ?? 'No album'} • ${m.folderId ?? 'No folder'}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w600,
                                                  color: (Theme.of(context)
                                                              .brightness ==
                                                          Brightness.dark
                                                      ? AppColors.subtitleOnDark
                                                      : AppColors.subtitle),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: 'Favorite',
                                          icon: Icon(
                                            m.isFavorite
                                                ? Icons.favorite_rounded
                                                : Icons.favorite_border_rounded,
                                            color: m.isFavorite
                                                ? AppColors.accent
                                                : (Theme.of(context)
                                                            .brightness ==
                                                        Brightness.dark
                                                    ? AppColors.subtitleOnDark
                                                    : AppColors.subtitle),
                                          ),
                                          onPressed: () => ref
                                              .read(mediaProvider)
                                              .toggleFavorite(m.id),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}
