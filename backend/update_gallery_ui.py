import re
import sys

file_path = "d:/picgallery/lib/screens/client/shared_gallery_screen.dart"

with open(file_path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Add _selectedFilterTab
if "_selectedFilterTab" not in content:
    content = content.replace(
        "bool get _isSelectionMode => _selectedIds.isNotEmpty;",
        "bool get _isSelectionMode => _selectedIds.isNotEmpty;\n  String _selectedFilterTab = 'All';"
    )

# 2. Add filteredMedia to _buildGallery
build_gallery_start = """    final hasCover = albumMedia.isNotEmpty;
    final coverMedia = hasCover ? albumMedia.first : null;"""

build_gallery_new_start = """    final hasCover = albumMedia.isNotEmpty;
    final coverMedia = hasCover ? albumMedia.first : null;

    final filteredMedia = albumMedia.where((m) {
      if (_selectedFilterTab == 'Photos') return m.type == MediaType.image;
      if (_selectedFilterTab == 'Videos') return m.type == MediaType.video;
      if (_selectedFilterTab == 'Favourite') return _favouriteIds.contains(m.id);
      return true;
    }).toList();"""

if "final filteredMedia =" not in content:
    content = content.replace(build_gallery_start, build_gallery_new_start)

# 3. Replace SliverAppBar and SliverToBoxAdapter
old_sliver_block = """            SliverAppBar(
              expandedHeight: 280,
              pinned: true,
              elevation: 0,
              leadingWidth: 64,
            leading: Padding(
              padding: EdgeInsets.only(left: 12),
              child: Center(
                child: InkWell(
                  onTap: () => Navigator.pop(context),
                  borderRadius: BorderRadius.circular(100),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                    ),
                    child: Icon(Icons.arrow_back_ios_new_rounded,
                        color: Colors.white, size: 16),
                  ),
                ),
              ),
            ),
            actions: [
              if (_isSelectionMode)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Center(
                    child: InkWell(
                      onTap: () {
                        setState(() {
                          if (_selectedIds.length == albumMedia.length) {
                            _selectedIds.clear();
                          } else {
                            _selectedIds.addAll(albumMedia.map((m) => m.id));
                          }
                        });
                      },
                      borderRadius: BorderRadius.circular(100),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        child: Icon(
                          _selectedIds.length == albumMedia.length ? Icons.deselect_rounded : Icons.select_all_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ),
              if (kIsWeb)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.4),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(100),
                          side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                        ),
                        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                      icon: Icon(Icons.open_in_new_rounded, size: 16),
                      label: Text('Open in App', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      onPressed: () async {
                        final uri = Uri.parse('picgallery://shared/${widget.token}');
                        final playStoreUri = Uri.parse('https://play.google.com/store/apps/details?id=com.mk.picgallery');
                        try {
                          if (!await launchUrl(uri)) {
                            // If custom scheme fails (app not installed), redirect to Play Store
                            await launchUrl(playStoreUri, mode: LaunchMode.externalApplication);
                          }
                        } catch (e) {
                          // Catch any platform exception and redirect to Play Store
                          await launchUrl(playStoreUri, mode: LaunchMode.externalApplication);
                        }
                      },
                    ),
                  ),
                ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                data.album?.name ?? data.collection?.name ?? 'Gallery',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  shadows: [
                    Shadow(
                        color: Colors.black54,
                        blurRadius: 4,
                        offset: Offset(0, 2))
                  ],
                ),
              ),
              centerTitle: true,
              background: Stack(
                fit: StackFit.expand,
                children: [
                  _buildCoverImage(coverMedia, data.album?.gradientArgb ?? const [0xFF7C5CFF, 0xFFA855F7, 0xFFEC4899]),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black38, Colors.black87],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.isPreview) ...[
                    _buildPreviewBanner(),
                    SizedBox(height: 12),
                  ],
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: data.requiresPassword
                              ? Colors.purple.withValues(alpha: 0.12)
                              : Colors.blue.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: data.requiresPassword
                                ? Colors.purple.withValues(alpha: 0.3)
                                : Colors.blue.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                                data.requiresPassword
                                    ? Icons.lock_open_rounded
                                    : Icons.public_rounded,
                                size: 12,
                                color: data.requiresPassword
                                    ? Colors.purple
                                    : Colors.blue),
                            SizedBox(width: 4),
                            Text(
                              data.requiresPassword
                                  ? 'Private Unlocked'
                                  : 'Public Gallery',
                              style: TextStyle(
                                  color: data.requiresPassword
                                      ? Colors.purple
                                      : Colors.blue,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 8),
                      Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          (data.albums != null && data.albums!.isNotEmpty)
                              ? '${data.albums!.length} Albums'
                              : '${albumMedia.length} Photos & Videos',
                          style: TextStyle(
                              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                              fontSize: 10,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const Spacer(),
                      PopupMenuButton<_ClientGalleryViewMode>(
                        tooltip: 'Change View Mode',
                        initialValue: _viewMode,
                        onSelected: _changeViewMode,
                        child: Container(
                          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.grey.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _viewMode == _ClientGalleryViewMode.compactGrid
                                    ? Icons.apps_rounded
                                    : _viewMode == _ClientGalleryViewMode.grid
                                        ? Icons.grid_view_rounded
                                        : _viewMode == _ClientGalleryViewMode.list
                                            ? Icons.view_list_rounded
                                            : Icons.table_rows_rounded,
                                size: 16,
                                color: Theme.of(context).brightness == Brightness.dark
                                    ? AppColors.textOnDark
                                    : AppColors.text,
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.arrow_drop_down,
                                  size: 16,
                                  color: Theme.of(context).brightness == Brightness.dark
                                      ? AppColors.textOnDark
                                      : AppColors.text),
                            ],
                          ),
                        ),
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: _ClientGalleryViewMode.compactGrid,
                            child: Text('Compact Grid'),
                          ),
                          const PopupMenuItem(
                            value: _ClientGalleryViewMode.grid,
                            child: Text('Grid'),
                          ),
                          const PopupMenuItem(
                            value: _ClientGalleryViewMode.list,
                            child: Text('List'),
                          ),
                          const PopupMenuItem(
                            value: _ClientGalleryViewMode.details,
                            child: Text('Details'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    (data.albums != null && data.albums!.isNotEmpty)
                        ? 'Welcome to your collection. Tap any album to view its gallery.'
                        : 'Welcome to your proofing gallery. Tap any image to review details, zoom, or playback video.',
                    style: TextStyle(
                        color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle), fontSize: 12, height: 1.4),
                  ),
                  SizedBox(height: 12),
                  Divider(color: context.borderColor),
                ],
              ),
            ),"""

# Using regex to find the block since formatting might be slightly off.
import re
match = re.search(r"SliverAppBar\(\s*expandedHeight: 280,.*?Divider\(color: context\.borderColor\),\s*],\s*\),\s*\),", content, re.DOTALL)
if match:
    new_sliver_block = """            SliverAppBar(
              pinned: true,
              elevation: 0,
              backgroundColor: Theme.of(context).scaffoldBackgroundColor,
              leadingWidth: 200,
              leading: Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(
                  children: [
                    InkWell(
                      onTap: () => Navigator.pop(context),
                      borderRadius: BorderRadius.circular(100),
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        child: Icon(Icons.arrow_back_ios_new_rounded, size: 18, color: Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Text('P', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('PicGallery', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text)),
                  ],
                ),
              ),
              actions: [
                IconButton(
                  icon: Icon(_isSelectionMode ? Icons.deselect_rounded : Icons.check_circle_outline_rounded, color: Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                  onPressed: () {
                    setState(() {
                      if (_selectedIds.length == filteredMedia.length && filteredMedia.isNotEmpty) {
                        _selectedIds.clear();
                      } else {
                        _selectedIds.addAll(filteredMedia.map((m) => m.id));
                      }
                    });
                  },
                ),
                IconButton(
                  icon: Icon(Icons.share_outlined, color: Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                  onPressed: () async {
                      final url = 'https://picgallery.studio/share/${widget.token}';
                      // share link logic - just standard share
                      // For now, if we have share_plus we'd use it, or just copy to clipboard
                      // Using url_launcher or copying to clipboard
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.isPreview) ...[
                      _buildPreviewBanner(),
                      const SizedBox(height: 12),
                    ],
                    _buildHeaderCard(context, data, albumMedia, controller),
                    const SizedBox(height: 24),
                    if (data.albums == null || data.albums!.isEmpty)
                      _buildFilterTabs(context),
                  ],
                ),
              ),
            ),"""
    content = content[:match.start()] + new_sliver_block + content[match.end():]

# Now we need to replace albumMedia[i] and albumMedia.length with filteredMedia.
# The grid starts after `(data.albums != null && data.albums!.isNotEmpty)` ... `else albumMedia.isEmpty`
content = content.replace("albumMedia.isEmpty", "filteredMedia.isEmpty")
content = content.replace("albumMedia.length", "filteredMedia.length")
content = content.replace("final m = albumMedia[i];", "final m = filteredMedia[i];")

# 4. Add new methods at the end of _SharedGalleryScreenState
new_methods = """  Widget _buildHeaderCard(BuildContext context, PublicGalleryData data, List<MediaModel> allMedia, PublicGalleryController controller) {
    final studioName = data.studioName ?? 'Studio';
    final studioInitials = studioName.isNotEmpty ? studioName[0].toUpperCase() : 'S';
    final title = data.album?.name ?? data.collection?.name ?? 'Shared Gallery';
    
    final photoCount = allMedia.where((m) => m.type == MediaType.image).length;
    final videoCount = allMedia.where((m) => m.type == MediaType.video).length;
    String countText = '';
    if (photoCount > 0) countText += '$photoCount photos';
    if (videoCount > 0) {
      if (countText.isNotEmpty) countText += ', ';
      countText += '$videoCount videos';
    }
    if (countText.isEmpty) countText = '0 items';
    if (data.albums != null && data.albums!.isNotEmpty) {
        countText = '${data.albums!.length} albums';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF13131A), // Dark background matching mockup
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Studio badge and name
          Row(
            children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: AppColors.primary,
                child: Text(
                  studioInitials,
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                studioName,
                style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Title
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
          // Chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.collections_rounded, size: 12, color: Colors.white),
                    const SizedBox(width: 6),
                    Text(countText, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              if (data.expiryDate != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.schedule_rounded, size: 12, color: Colors.white),
                      const SizedBox(width: 6),
                      Text(
                        '${data.expiryDate!.difference(DateTime.now()).inDays} days left',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          // Action Buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                     if (data.allowDownload) {
                        _downloadMediaIds(allMedia.map((e) => e.id).toList(), data, allMedia, context, ref, _gridFileCache, _gridDownloadService);
                     } else {
                         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Downloads are disabled for this gallery.')));
                     }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Download all', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    ref.read(faceSearchProvider.notifier).useSharedGallery(
                      token: widget.token,
                      password: controller.password,
                    );
                    Navigator.of(context).pushNamed(AppRoutes.faceSearchUpload);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.face_retouching_natural_rounded, size: 18),
                  label: const Text('Find my photos', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterTabs(BuildContext context) {
    final tabs = ['All', 'Photos', 'Videos', 'Favourite'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: tabs.map((t) {
          final isSelected = _selectedFilterTab == t;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              onTap: () {
                setState(() {
                  _selectedFilterTab = t;
                });
              },
              borderRadius: BorderRadius.circular(100),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? AppColors.primary : Colors.transparent,
                  border: Border.all(color: isSelected ? AppColors.primary : context.borderColor),
                  borderRadius: BorderRadius.circular(100),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t == 'Favourite') ...[
                        Icon(isSelected ? Icons.favorite_rounded : Icons.favorite_border_rounded, 
                            size: 14, 
                            color: isSelected ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text)),
                        const SizedBox(width: 6),
                    ],
                    Text(
                      t,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: isSelected ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                      ),
                    ),
                    if (t == 'Favourite') ...[
                        const SizedBox(width: 6),
                        Text(
                          _favouriteIds.length.toString(),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: isSelected ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
"""

if "_buildFilterTabs" not in content:
    content = content.replace("}\n", new_methods, 1) # Note: Replace the LAST `}` of _SharedGalleryScreenState. Let's do it better.
    
    # Find the last closing brace of the file and put it before that.
    # Actually, the file has no other classes after _SharedGalleryScreenState except it's the last one.
    content = content[:-2] + new_methods

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)
print("Updated dart file.")