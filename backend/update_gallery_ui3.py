import sys

file_path = "d:/picgallery/lib/screens/client/shared_gallery_screen.dart"

with open(file_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
in_build_gallery = False
for i, line in enumerate(lines):
    if "bool get _isSelectionMode => _selectedIds.isNotEmpty;" in line:
        out.append(line)
        out.append("  String _selectedFilterTab = 'All';\n")
        continue

    if "final hasCover = albumMedia.isNotEmpty;" in line:
        out.append(line)
        out.append("""
    final filteredMedia = albumMedia.where((m) {
      if (_selectedFilterTab == 'Photos') return m.type == MediaType.photo;
      if (_selectedFilterTab == 'Videos') return m.type == MediaType.video;
      if (_selectedFilterTab == 'Favourite') return _favouriteIds.contains(m.id);
      return true;
    }).toList();
""")
        continue

    # Skip SliverAppBar up to the end of SliverToBoxAdapter
    if "SliverAppBar(" in line and "expandedHeight: 280," in lines[i+1]:
        # We need to replace a massive block. Let's just output the new block and skip lines until the next sliver.
        new_block = """            SliverAppBar(
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
                      // share link logic
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
            ),
"""
        out.append(new_block)
        # We must skip until we find the end of SliverToBoxAdapter.
        # It ends around line 957.
        continue

    out.append(line)

content = "".join(out)

# Now we must remove the old SliverAppBar and SliverToBoxAdapter block manually.
import re
match = re.search(r"SliverAppBar\(\s*expandedHeight: 280,.*?Divider\(color: context\.borderColor\),\s*],\s*\),\s*\),\s*\),", content, re.DOTALL)
if match:
    # Oh wait, we already inserted the new block, we have BOTH now?
    pass

# Let's just do standard replace on the full content.
content = content.replace("albumMedia.isEmpty", "filteredMedia.isEmpty")
content = content.replace("albumMedia.length", "filteredMedia.length")
content = content.replace("final m = albumMedia[i];", "final m = filteredMedia[i];")
content = content.replace("_buildGridItem(\n                                            context, m, albumMedia", "_buildGridItem(\n                                            context, m, filteredMedia")
content = content.replace("_buildGridItem(context, m, albumMedia", "_buildGridItem(context, m, filteredMedia")


new_methods = """  Widget _buildHeaderCard(BuildContext context, PublicGalleryData data, List<MediaModel> allMedia, PublicGalleryController controller) {
    final studioName = data.studioName ?? 'Studio';
    final studioInitials = studioName.isNotEmpty ? studioName[0].toUpperCase() : 'S';
    final title = data.album?.name ?? data.collection?.name ?? 'Shared Gallery';
    
    final photoCount = allMedia.where((m) => m.type == MediaType.photo).length;
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
        color: const Color(0xFF13131A),
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
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 12),
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

last_brace = content.rfind('}')
if last_brace != -1:
    content = content[:last_brace] + new_methods + "\\n"

with open(file_path, "w", encoding="utf-8") as f:
    f.write(content)

print("Updated without regex block replacement issues (maybe).")
