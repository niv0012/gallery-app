import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../models/share_link_model.dart';
import '../../providers/share_link_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';

class ShareLinksListScreen extends ConsumerStatefulWidget {
  final String? folderId;
  final String? albumId;
  final String title;

  const ShareLinksListScreen({
    Key? key,
    this.folderId,
    this.albumId,
    required this.title,
  }) : super(key: key);

  @override
  ConsumerState<ShareLinksListScreen> createState() => _ShareLinksListScreenState();
}

class _ShareLinksListScreenState extends ConsumerState<ShareLinksListScreen> {
  @override
  Widget build(BuildContext context) {
    final target = ShareTarget(folderId: widget.folderId, albumId: widget.albumId);
    final linkState = ref.watch(shareLinkControllerProvider(target));

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: CustomAppBar(
        title: 'Share Links: ${widget.title}',
        showBack: true,
      ),
      body: ScreenBackdrop(
        child: SafeArea(
          child: linkState.isLoading
              ? const Center(child: CircularProgressIndicator())
              : linkState.error != null
                  ? Center(child: Text(linkState.error!))
                  : linkState.activeLinks.isEmpty
                      ? _buildEmptyState()
                      : _buildList(linkState.activeLinks),
        ),
      ),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          gradient: AppColors.heroGradient,
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withOpacity(0.4),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: FloatingActionButton.extended(
          backgroundColor: Colors.transparent,
          elevation: 0,
          highlightElevation: 0,
          onPressed: () => _openLinkSettings(null),
          icon: const Icon(Icons.add, color: Colors.white),
          label: const Text('New Link', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.link_off_rounded, size: 64, color: AppColors.primary),
          ),
          const SizedBox(height: 24),
          const Text(
            'No Active Share Links',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Create a new link to share this content. You can manage multiple links with different permissions.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.subtitle, fontSize: 16, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<GalleryShareLink> links) {
    return ListView.separated(
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        top: AppSpacing.md,
        bottom: 100, // padding for FAB
      ),
      itemCount: links.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final link = links[index];
        final isFaceSearch = link.kind == 'face_search';
        final isPrivate = link.hasPassword;
        final isClient = link.clientId != null;
        
        final typeLabel = isFaceSearch 
            ? 'Face Search' 
            : isClient
                ? 'Client Delivery'
                : isPrivate 
                    ? 'Private' 
                    : 'Public Access';
        
        final icon = isFaceSearch
            ? Icons.face_retouching_natural_rounded
            : isClient
                ? Icons.person_pin_rounded
                : isPrivate
                    ? Icons.lock_rounded
                    : Icons.public_rounded;

        final color = isFaceSearch
            ? AppColors.accent
            : isClient
                ? AppColors.secondary
                : isPrivate
                    ? AppColors.warning
                    : AppColors.primary;

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.border.withOpacity(0.5)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.03),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openLinkSettings(link),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: color, size: 26),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$typeLabel Link',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(Icons.visibility_rounded, size: 14, color: AppColors.subtitle),
                              const SizedBox(width: 4),
                              Text('${link.viewsCount}', style: TextStyle(color: AppColors.subtitle, fontSize: 13)),
                              const SizedBox(width: 12),
                              Icon(Icons.download_rounded, size: 14, color: AppColors.subtitle),
                              const SizedBox(width: 4),
                              Text('${link.downloadsCount}', style: TextStyle(color: AppColors.subtitle, fontSize: 13)),
                              if (link.expiresAt != null) ...[
                                const SizedBox(width: 12),
                                Icon(Icons.timer_outlined, size: 14, color: AppColors.subtitle),
                                const SizedBox(width: 4),
                                Text(
                                  'Expires soon', // We can format this date properly if needed
                                  style: TextStyle(color: AppColors.subtitle, fontSize: 13),
                                ),
                              ]
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: link.primaryShareUrl));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Link copied!')));
                                  },
                                  icon: const Icon(Icons.copy_rounded, size: 14),
                                  label: const Text('Copy', style: TextStyle(fontSize: 12)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => Share.share(link.primaryShareUrl, subject: 'View my photo gallery'),
                                  icon: const Icon(Icons.share_rounded, size: 14),
                                  label: const Text('Share', style: TextStyle(fontSize: 12)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: () => launchUrlString(link.primaryShareUrl, mode: LaunchMode.externalApplication),
                                  icon: const Icon(Icons.open_in_browser_rounded, size: 14),
                                  label: const Text('Open', style: TextStyle(fontSize: 12)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, color: AppColors.subtitle),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _openLinkSettings(GalleryShareLink? link) {
    if (widget.folderId != null) {
      Navigator.of(context).pushNamed(
        AppRoutes.folderShareSettings,
        arguments: {
          'folderId': widget.folderId!,
          'folderName': widget.title,
          'link': link,
        },
      );
    } else if (widget.albumId != null) {
      Navigator.of(context).pushNamed(
        AppRoutes.albumShareSettings,
        arguments: {
          'albumId': widget.albumId!,
          'albumName': widget.title,
          'link': link,
        },
      );
    }
  }
}
