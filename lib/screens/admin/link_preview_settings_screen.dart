import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/auth_providers.dart';

enum LinkPreviewType { coverPhoto, logo, defaultPicGallery }

class LinkPreviewSettingsScreen extends ConsumerStatefulWidget {
  const LinkPreviewSettingsScreen({super.key});

  @override
  ConsumerState<LinkPreviewSettingsScreen> createState() => _LinkPreviewSettingsScreenState();
}

class _LinkPreviewSettingsScreenState extends ConsumerState<LinkPreviewSettingsScreen> {
  // Local state for the selected option. In the future, this will be saved to the user model.
  LinkPreviewType _selectedType = LinkPreviewType.coverPhoto;

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final user = authState.user;

    final studioName = user?.studioName ?? 'Sharma Studio';
    final coverUrl = user?.coverImageUrl;
    final logoUrl = user?.avatarUrl;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.text),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Studio preview settings', style: TextStyle(color: AppColors.text)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Link preview',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'What clients see when you send a gallery link on WhatsApp.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 32),

            // Preview Card
            _buildPreviewCard(studioName, coverUrl, logoUrl),
            
            const SizedBox(height: 32),
            
            Text(
              'Show in link',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            
            // Toggle Buttons
            Row(
              children: [
                Expanded(child: _buildOptionButton(LinkPreviewType.coverPhoto, 'Cover photo')),
                const SizedBox(width: 8),
                Expanded(child: _buildOptionButton(LinkPreviewType.logo, 'Logo')),
                const SizedBox(width: 8),
                Expanded(child: _buildOptionButton(LinkPreviewType.defaultPicGallery, 'Default')),
              ],
            ),
            
            const SizedBox(height: 24),
            
            // Info text based on selection
            if (_selectedType == LinkPreviewType.coverPhoto) ...[
              const Text('Cover photo', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('studio-cover.jpg'),
                    TextButton(
                      onPressed: () {
                         // TODO: navigate to profile edit
                      },
                      child: const Text('Change', style: TextStyle(color: AppColors.primary)),
                    )
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'PicGallery badge always shows on the image. Password-protected links use your logo, never client photos.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              ),
            ),
            
            const SizedBox(height: 48),
            
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () {
                  // TODO: Save preference to backend/provider
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Preferences saved (Mock)')),
                  );
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Save', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildOptionButton(LinkPreviewType type, String label) {
    final isSelected = _selectedType == type;
    return InkWell(
      onTap: () => setState(() => _selectedType = type),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.text : Colors.transparent,
          border: Border.all(color: isSelected ? AppColors.text : Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : AppColors.text,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewCard(String studioName, String? coverUrl, String? logoUrl) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The Image Part
          ClipRRect(
            borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
            child: SizedBox(
              height: 200,
              width: double.infinity,
              child: _buildImageContent(studioName, coverUrl, logoUrl),
            ),
          ),
          
          // The Link Text Part
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$studioName — Client Gallery',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Shared via PicGallery • View, download & select your favourites',
                  style: TextStyle(color: Colors.grey, fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                const Text(
                  'api.picgallery.in',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }

  Widget _buildImageContent(String studioName, String? coverUrl, String? logoUrl) {
    if (_selectedType == LinkPreviewType.coverPhoto) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (coverUrl != null && coverUrl.isNotEmpty)
            Image.network(coverUrl, fit: BoxFit.cover)
          else
            Container(color: const Color(0xFFC4A484)), // Placeholder beige color
            
          // Mock Bottom Studio Bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: const Color(0xFF0F172A), // Dark slate color
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.white,
                    backgroundImage: logoUrl != null && logoUrl.isNotEmpty ? NetworkImage(logoUrl) : null,
                    child: logoUrl == null || logoUrl.isEmpty
                        ? Text(studioName.isNotEmpty ? studioName[0] : 'S', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold))
                        : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      studioName,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  )
                ],
              ),
            ),
          ),
          
          // PicGallery Badge
          const Positioned(
            top: 16,
            left: 16,
            child: _PicGalleryBadge(),
          )
        ],
      );
    } else if (_selectedType == LinkPreviewType.logo) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Container(color: const Color(0xFF0F172A)), // Dark slate color
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.white,
                  backgroundImage: logoUrl != null && logoUrl.isNotEmpty ? NetworkImage(logoUrl) : null,
                  child: logoUrl == null || logoUrl.isEmpty
                      ? Text(studioName.isNotEmpty ? studioName[0] : 'S', style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 24))
                      : null,
                ),
                const SizedBox(width: 16),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      studioName,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
                    ),
                    const Text(
                      'Your photos are ready',
                      style: TextStyle(color: Color(0xFFFBBF24), fontSize: 14), // Yellow accent
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Positioned(
            top: 16,
            left: 16,
            child: _PicGalleryBadge(),
          )
        ],
      );
    } else {
      // Default PicGallery
      return Stack(
        fit: StackFit.expand,
        children: [
          Container(color: const Color(0xFF0F172A)),
          const Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your Photos\nAre Ready',
                  style: TextStyle(color: Color(0xFFFBBF24), fontWeight: FontWeight.bold, fontSize: 28, height: 1.2),
                ),
                SizedBox(height: 8),
                Text(
                  'View, download & select',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ],
            ),
          ),
          const Positioned(
            top: 16,
            left: 16,
            child: _PicGalleryBadge(),
          )
        ],
      );
    }
  }
}

class _PicGalleryBadge extends StatelessWidget {
  const _PicGalleryBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A), // Dark slate
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: const Color(0xFF6366F1), // Indigo primary
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Icon(Icons.photo_library, size: 10, color: Colors.white),
          ),
          const SizedBox(width: 6),
          const Text('picgallery', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
