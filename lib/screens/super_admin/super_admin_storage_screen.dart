import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/admin_api_client.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/csv_utils.dart';
import '../../core/utils/format_utils.dart';
import 'super_admin_dashboard_screen.dart' show kStorageWarningThreshold, kStorageCriticalThreshold;
import 'super_admin_user_detail_screen.dart';
import '../../core/theme/theme_context.dart';

/// Screen displaying platform-wide storage usage against 24TB total capacity,
/// with a breakdown of top storage users sorted by heaviest usage.
class SuperAdminStorageScreen extends StatefulWidget {
  final StorageSummary storageSummary;
  final List<PlatformUser> allUsers;

  const SuperAdminStorageScreen({
    super.key,
    required this.storageSummary,
    required this.allUsers,
  });

  @override
  State<SuperAdminStorageScreen> createState() =>
      _SuperAdminStorageScreenState();
}

class _SuperAdminStorageScreenState extends State<SuperAdminStorageScreen> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _exportCsv(List<PlatformUser> users) async {
    if (users.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing to export')),
      );
      return;
    }
    final csv = usersStorageToCsv(users);
    final bytes = utf8.encode(csv);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: 'storage_by_user.csv', mimeType: 'text/csv')],
        subject: 'Storage by user — ${DateTime.now().toIso8601String().split('T').first}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Attach storage bytes to users and sort heaviest first
    final usersWithStorage = widget.allUsers.map((u) {
      final bytes = widget.storageSummary.usedBytesByUserId[u.id] ?? 0;
      return u.copyWith(usedBytes: bytes);
    }).toList();

    usersWithStorage.sort((a, b) => (b.usedBytes ?? 0).compareTo(a.usedBytes ?? 0));

    final filteredUsers = usersWithStorage.where((u) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return u.fullName.toLowerCase().contains(q) ||
          u.email.toLowerCase().contains(q) ||
          (u.studioName?.toLowerCase().contains(q) ?? false);
    }).toList();

    final used = widget.storageSummary.totalUsedBytes;
    final total = widget.storageSummary.totalCapacityBytes;
    final pct = widget.storageSummary.usedPercentage;

    return Scaffold(
      backgroundColor: context.bgColor,
      appBar: AppBar(
        backgroundColor: context.bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: context.textPrimary),
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Storage Overview',
          style: TextStyle(
            color: context.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.ios_share_rounded, color: context.textPrimary),
            tooltip: 'Export CSV',
            onPressed: () => _exportCsv(filteredUsers),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pct >= kStorageWarningThreshold) ...[
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: (pct >= kStorageCriticalThreshold ? AppColors.error : AppColors.warning)
                      .withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(
                      color: (pct >= kStorageCriticalThreshold ? AppColors.error : AppColors.warning)
                          .withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    Icon(
                      pct >= kStorageCriticalThreshold
                          ? Icons.error_rounded
                          : Icons.warning_amber_rounded,
                      color: pct >= kStorageCriticalThreshold ? AppColors.error : AppColors.warning,
                      size: 24,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        pct >= kStorageCriticalThreshold
                            ? 'Storage critically full — ${pct.toStringAsFixed(1)}% used. Uploads may start failing.'
                            : 'Storage nearly full — ${pct.toStringAsFixed(1)}% used (${formatBytes(used)} of ${formatBytes(total)})',
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            // Big Storage Usage Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                gradient: AppColors.heroGradient,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: const Icon(
                          Icons.cloud_done_rounded,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Server Capacity',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '${formatBytes(used)} / ${formatBytes(total)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.4,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(
                          '${pct.toStringAsFixed(1)}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    child: LinearProgressIndicator(
                      value: (pct / 100).clamp(0.0, 1.0),
                      minHeight: 10,
                      backgroundColor: Colors.white.withValues(alpha: 0.2),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '${formatBytes(total - used)} available of ${formatBytes(total)} total capacity',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),

            // Top Users Section Title
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Storage by User',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  '${usersWithStorage.length} Users',
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),

            // Search Box
            TextField(
              controller: _searchController,
              onChanged: (val) => setState(() {
                _searchQuery = val.trim();
              }),
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search user by name or email...',
                hintStyle: TextStyle(color: context.textMuted),
                prefixIcon: Icon(Icons.search_rounded,
                    color: context.textMuted, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear_rounded,
                            color: context.textMuted, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      )
                    : null,
                filled: true,
                fillColor: context.surfaceColor,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: context.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(color: context.borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: const BorderSide(color: AppColors.primary),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),

            // Users List Sorted by Storage
            if (filteredUsers.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.xl),
                decoration: BoxDecoration(
                  color: context.surfaceColor,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: context.borderColor),
                ),
                child: Column(
                  children: [
                    Icon(Icons.storage_rounded,
                        color: context.textMuted, size: 36),
                    SizedBox(height: 8),
                    Text(
                      'No storage records match your search.',
                      style: TextStyle(color: context.textMuted, fontSize: 13.5),
                    ),
                  ],
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: filteredUsers.length,
                separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final user = filteredUsers[index];
                  final bytes = user.usedBytes ?? 0;

                  return Container(
                    decoration: BoxDecoration(
                      color: context.surfaceColor,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: context.borderColor),
                    ),
                    child: ListTile(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SuperAdminUserDetailScreen(user: user),
                        ),
                      ),
                      leading: CircleAvatar(
                        backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                        child: Text(
                          user.initials,
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      title: Text(
                        user.fullName,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5,
                        ),
                      ),
                      subtitle: Text(
                        '${user.isStudio ? "Studio" : "Client"} • ${user.email}',
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: bytes > 0
                              ? AppColors.primary.withValues(alpha: 0.12)
                              : Colors.black.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          formatBytes(bytes),
                          style: TextStyle(
                            color: bytes > 0 ? AppColors.primary : context.textMuted,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
