import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/constants/app_constants.dart';
import '../../models/share_link_model.dart';
import '../../providers/share_link_provider.dart';
import '../../widgets/common/empty_state_card.dart';
import '../../widgets/common/loading_widget.dart';

class LinkAnalyticsScreen extends ConsumerStatefulWidget {
  final String linkId;
  final GalleryShareLink link;

  const LinkAnalyticsScreen({
    super.key,
    required this.linkId,
    required this.link,
  });

  @override
  ConsumerState<LinkAnalyticsScreen> createState() => _LinkAnalyticsScreenState();
}

class _LinkAnalyticsScreenState extends ConsumerState<LinkAnalyticsScreen> {
  bool _isLoading = true;
  String? _error;
  ShareLinkAnalyticsModel? _analytics;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final repo = ref.read(shareLinkRepositoryProvider);
      final data = await repo.fetchAnalytics(widget.linkId);
      setState(() {
        _analytics = data;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Link Analytics'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          )
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: LoadingWidget(message: 'Loading analytics...'));
    }
    if (_error != null) {
      return Center(
        child: EmptyStateCard(
          message: _error!,
        ),
      );
    }
    final data = _analytics;
    if (data == null) {
      return const Center(child: Text('No analytics data available.'));
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _buildStatCard(
          'Total Views',
          data.viewsCount.toString(),
          Icons.visibility_outlined,
          Colors.blue,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildStatCard(
          'Downloads',
          data.downloadsCount.toString(),
          Icons.download_outlined,
          Colors.green,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildStatCard(
          'Face Searches',
          data.faceSearchesCount.toString(),
          Icons.face_retouching_natural,
          Colors.purple,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildStatCard(
          'Client Favourites',
          data.favouritesCount.toString(),
          Icons.favorite_border,
          Colors.red,
        ),
        const SizedBox(height: AppSpacing.md),
        if (data.favouritesBreakdown.isNotEmpty) ...[
          const Text(
            'Top Favourites',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: AppSpacing.sm),
          ...data.favouritesBreakdown.map((item) {
            final count = item['count'];
            return ListTile(
              leading: const Icon(Icons.image),
              title: Text('Media: ${item['media_id']}'),
              trailing: Text('$count favourites'),
            );
          }),
          const SizedBox(height: AppSpacing.md),
        ],
        _buildStatCard(
          'Emails Captured',
          data.emailsSubmitted.toString(),
          Icons.email_outlined,
          Colors.orange,
        ),
        if (data.emailsCaptured.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          const Text(
            'Captured Emails',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: AppSpacing.sm),
          ...data.emailsCaptured.map((e) => ListTile(
                leading: const Icon(Icons.person),
                title: Text(e),
              )),
        ]
      ],
    );
  }

  Widget _buildStatCard(
      String title, String value, IconData icon, Color iconColor) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: iconColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 4),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 24, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
