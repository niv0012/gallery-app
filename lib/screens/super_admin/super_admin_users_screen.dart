import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api/admin_api_client.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/csv_utils.dart';
import '../../core/utils/format_utils.dart';
import 'super_admin_user_detail_screen.dart';
import '../../core/theme/theme_context.dart';

class _UsersScreenData {
  final PlatformUsers users;
  final StorageSummary storage;
  _UsersScreenData(this.users, this.storage);
}

class SuperAdminUsersScreen extends StatefulWidget {
  final int initialTab;
  final bool suspendedOnly;

  const SuperAdminUsersScreen({
    super.key,
    this.initialTab = 0,
    this.suspendedOnly = false,
  });

  @override
  State<SuperAdminUsersScreen> createState() => _SuperAdminUsersScreenState();
}

class _SuperAdminUsersScreenState extends State<SuperAdminUsersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _searchController = TextEditingController();
  String _query = '';
  bool _sortByStorage = false;
  late Future<_UsersScreenData> _dataFuture;

  bool _selectMode = false;
  Set<String> _selectedIds = {};
  bool _bulkLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: 2, vsync: this, initialIndex: widget.initialTab.clamp(0, 1));
    _tabController.addListener(_onTabChanged);
    _dataFuture = _loadData();
  }

  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  Future<_UsersScreenData> _loadData() async {
    final results = await Future.wait([
      AdminApiClient.instance.fetchUsers(),
      AdminApiClient.instance.fetchStorageSummary(),
    ]);
    return _UsersScreenData(
      results[0] as PlatformUsers,
      results[1] as StorageSummary,
    );
  }

  Future<void> _refresh() async {
    final future = _loadData();
    setState(() {
      _dataFuture = future;
    });
    await future;
  }

  String get _title {
    if (widget.suspendedOnly) return 'Suspended accounts';
    return 'Users';
  }

  String? get _subtitle {
    if (widget.suspendedOnly) {
      return 'Accounts a Super Admin has suspended — they can no longer sign in.';
    }
    return null;
  }

  List<PlatformUser> _filtered(List<PlatformUser> users) {
    if (widget.suspendedOnly) return users.where((u) => !u.isActive).toList();
    return users;
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _onLongPressSelect(String id) {
    setState(() {
      _selectMode = true;
      _selectedIds.add(id);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds = {};
    });
  }

  Future<void> _bulkSetActive(bool active) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    setState(() {
      _bulkLoading = true;
    });
    try {
      final results = await Future.wait(
        ids.map((id) => active
            ? AdminApiClient.instance.unsuspendUser(id)
            : AdminApiClient.instance.suspendUser(id)),
        eagerError: false,
      );
      if (!mounted) return;
      setState(() {
        _bulkLoading = false;
        _selectMode = false;
        _selectedIds = {};
      });
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${results.length} account(s) updated.'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _bulkLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e is AdminApiException ? e.message : 'Error updating accounts: $e'),
      ));
    }
  }

  Future<void> _exportSelectedCsv(List<PlatformUser> selectedUsers) async {
    if (selectedUsers.isEmpty) return;
    final csv = usersStorageToCsv(selectedUsers);
    final bytes = utf8.encode(csv);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: 'users_export.csv', mimeType: 'text/csv')],
        subject: 'Users Export — ${DateTime.now().toIso8601String().split('T').first}',
      ),
    );
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_UsersScreenData>(
      future: _dataFuture,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final isLoading = snapshot.connectionState != ConnectionState.done;
        final hasError = snapshot.hasError;

        List<PlatformUser> studios = [];
        List<PlatformUser> clients = [];
        List<PlatformUser> allUsersList = [];
        PlatformUsers? allMappedUsers;

        if (data != null) {
          final storageMap = data.storage.usedBytesByUserId;
          PlatformUser mapUser(PlatformUser u) => u.copyWith(
                usedBytes: storageMap[u.id] ?? 0,
              );

          final studiosWithStorage = data.users.studios.map(mapUser).toList();
          final clientsWithStorage = data.users.clients.map(mapUser).toList();

          studios = _filtered(studiosWithStorage);
          clients = _filtered(clientsWithStorage);

          allUsersList = [...studiosWithStorage, ...clientsWithStorage];
          allMappedUsers = PlatformUsers(
            studios: studiosWithStorage,
            clients: clientsWithStorage,
          );
        }

        final currentTabUsers = _tabController.index == 0 ? studios : clients;
        final currentTabHasUsers = currentTabUsers.isNotEmpty;

        final selectedUsers = allUsersList
            .where((u) => _selectedIds.contains(u.id))
            .toList();
        final hasActive = selectedUsers.any((u) => u.isActive);
        final hasSuspended = selectedUsers.any((u) => !u.isActive);

        return Scaffold(
          backgroundColor: context.bgColor,
          appBar: AppBar(
            backgroundColor: context.bgColor,
            elevation: 0,
            iconTheme: IconThemeData(color: context.textPrimary),
            title: Text(_title,
                style: TextStyle(
                    color: context.textPrimary, fontWeight: FontWeight.w700, fontSize: 18)),
            actions: [
              if (_selectMode)
                TextButton(
                  onPressed: _exitSelectMode,
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else if (currentTabHasUsers && !isLoading && !hasError)
                IconButton(
                  icon: Icon(Icons.checklist_rounded, color: context.textPrimary),
                  tooltip: 'Select mode',
                  onPressed: () => setState(() {
                    _selectMode = true;
                  }),
                ),
            ],
            bottom: TabBar(
              controller: _tabController,
              labelColor: AppColors.primary,
              unselectedLabelColor: context.textMuted,
              indicatorColor: AppColors.primary,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              tabs: const [
                Tab(text: 'Studio'),
                Tab(text: 'Client'),
              ],
            ),
          ),
          bottomNavigationBar: _selectMode
              ? SafeArea(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md, vertical: 10),
                    decoration: BoxDecoration(
                      color: context.surfaceColor,
                      border: Border(top: BorderSide(color: context.borderColor)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: const Offset(0, -4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_bulkLoading)
                          const Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: LinearProgressIndicator(),
                          ),
                        Row(
                          children: [
                            Text(
                              '${_selectedIds.length} selected',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                                color: context.textPrimary,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.ios_share_rounded, size: 20),
                              tooltip: 'Export CSV',
                              onPressed: (_bulkLoading || _selectedIds.isEmpty)
                                  ? null
                                  : () => _exportSelectedCsv(selectedUsers),
                            ),
                            const SizedBox(width: 4),
                            OutlinedButton(
                              onPressed: (_bulkLoading || !hasActive)
                                  ? null
                                  : () => _bulkSetActive(false),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppColors.error,
                                side: BorderSide(
                                  color: hasActive
                                      ? AppColors.error
                                      : context.borderColor,
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                              ),
                              child: const Text('Suspend',
                                  style: TextStyle(fontSize: 12.5)),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed: (_bulkLoading || !hasSuspended)
                                  ? null
                                  : () => _bulkSetActive(true),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                              ),
                              child: const Text('Reactivate',
                                  style: TextStyle(fontSize: 12.5)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                )
              : null,
          body: Column(
            children: [
              if (_subtitle != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                  child: Text(
                    _subtitle!,
                    style: TextStyle(fontSize: 12.5, color: context.textMuted),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md, AppSpacing.sm, AppSpacing.md, AppSpacing.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: (v) => setState(() {
                          _query = v.trim().toLowerCase();
                        }),
                        decoration: InputDecoration(
                          hintText: 'Search by name or email',
                          prefixIcon: Icon(Icons.search_rounded,
                              color: context.textMuted),
                          filled: true,
                          fillColor: context.surfaceColor,
                          contentPadding: const EdgeInsets.symmetric(vertical: 0),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            borderSide: BorderSide(color: context.borderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.pill),
                            borderSide: BorderSide(color: context.borderColor),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: Icon(
                        Icons.sort_rounded,
                        color:
                            _sortByStorage ? AppColors.primary : context.textMuted,
                      ),
                      tooltip:
                          _sortByStorage ? 'Sorted by Storage' : 'Sort by Storage',
                      onPressed: () => setState(() {
                        _sortByStorage = !_sortByStorage;
                      }),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Builder(
                  builder: (context) {
                    if (isLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (hasError) {
                      return _ErrorState(
                        message: snapshot.error is AdminApiException
                            ? (snapshot.error as AdminApiException).message
                            : 'Could not load users.',
                        onRetry: _refresh,
                      );
                    }

                    return RefreshIndicator(
                      onRefresh: _refresh,
                      child: TabBarView(
                        controller: _tabController,
                        children: [
                          _StudioList(
                            query: _query,
                            studios: studios,
                            allUsers: allMappedUsers!,
                            sortByStorage: _sortByStorage,
                            onChanged: _refresh,
                            selectMode: _selectMode,
                            selectedIds: _selectedIds,
                            onToggleSelect: _toggleSelect,
                            onLongPressSelect: _onLongPressSelect,
                            emptyLabel: widget.suspendedOnly
                                ? 'No suspended studio accounts found'
                                : 'No studios found',
                          ),
                          _ClientList(
                            query: _query,
                            clients: clients,
                            allUsers: allMappedUsers,
                            sortByStorage: _sortByStorage,
                            onChanged: _refresh,
                            selectMode: _selectMode,
                            selectedIds: _selectedIds,
                            onToggleSelect: _toggleSelect,
                            onLongPressSelect: _onLongPressSelect,
                            emptyLabel: widget.suspendedOnly
                                ? 'No suspended client accounts found'
                                : 'No clients found',
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, color: context.textMuted, size: 32),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textMuted)),
          ),
          const SizedBox(height: 12),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _StudioList extends StatelessWidget {
  final String query;
  final List<PlatformUser> studios;
  final PlatformUsers allUsers;
  final bool sortByStorage;
  final String emptyLabel;
  final VoidCallback? onChanged;
  final bool selectMode;
  final Set<String> selectedIds;
  final ValueChanged<String>? onToggleSelect;
  final ValueChanged<String>? onLongPressSelect;

  const _StudioList({
    required this.query,
    required this.studios,
    required this.allUsers,
    required this.sortByStorage,
    this.emptyLabel = 'No studios found',
    this.onChanged,
    this.selectMode = false,
    this.selectedIds = const {},
    this.onToggleSelect,
    this.onLongPressSelect,
  });

  @override
  Widget build(BuildContext context) {
    var items = studios.where((u) =>
        u.fullName.toLowerCase().contains(query) ||
        u.email.toLowerCase().contains(query) ||
        (u.studioName ?? '').toLowerCase().contains(query)).toList();

    if (sortByStorage) {
      items.sort((a, b) => (b.usedBytes ?? 0).compareTo(a.usedBytes ?? 0));
    }

    if (items.isEmpty) return _EmptyList(label: emptyLabel);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
      itemCount: items.length,
      itemBuilder: (context, i) => _UserTile(
        user: items[i],
        allUsers: allUsers,
        onChanged: onChanged,
        selectMode: selectMode,
        isSelected: selectedIds.contains(items[i].id),
        onToggleSelect: onToggleSelect,
        onLongPressSelect: onLongPressSelect,
      ),
    );
  }
}

class _ClientList extends StatelessWidget {
  final String query;
  final List<PlatformUser> clients;
  final PlatformUsers allUsers;
  final bool sortByStorage;
  final String emptyLabel;
  final VoidCallback? onChanged;
  final bool selectMode;
  final Set<String> selectedIds;
  final ValueChanged<String>? onToggleSelect;
  final ValueChanged<String>? onLongPressSelect;

  const _ClientList({
    required this.query,
    required this.clients,
    required this.allUsers,
    required this.sortByStorage,
    this.emptyLabel = 'No clients found',
    this.onChanged,
    this.selectMode = false,
    this.selectedIds = const {},
    this.onToggleSelect,
    this.onLongPressSelect,
  });

  @override
  Widget build(BuildContext context) {
    var items = clients.where((u) =>
        u.fullName.toLowerCase().contains(query) ||
        u.email.toLowerCase().contains(query)).toList();

    if (sortByStorage) {
      items.sort((a, b) => (b.usedBytes ?? 0).compareTo(a.usedBytes ?? 0));
    }

    if (items.isEmpty) return _EmptyList(label: emptyLabel);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, 0, AppSpacing.md, AppSpacing.lg),
      itemCount: items.length,
      itemBuilder: (context, i) => _UserTile(
        user: items[i],
        allUsers: allUsers,
        onChanged: onChanged,
        selectMode: selectMode,
        isSelected: selectedIds.contains(items[i].id),
        onToggleSelect: onToggleSelect,
        onLongPressSelect: onLongPressSelect,
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  final PlatformUser user;
  final PlatformUsers allUsers;
  final VoidCallback? onChanged;
  final bool selectMode;
  final bool isSelected;
  final ValueChanged<String>? onToggleSelect;
  final ValueChanged<String>? onLongPressSelect;

  const _UserTile({
    required this.user,
    required this.allUsers,
    this.onChanged,
    this.selectMode = false,
    this.isSelected = false,
    this.onToggleSelect,
    this.onLongPressSelect,
  });

  @override
  Widget build(BuildContext context) {
    final isStudio = user.isStudio;
    final suspended = !user.isActive;
    final storageBytes = user.usedBytes ?? 0;

    return Opacity(
      opacity: suspended ? 0.7 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isSelected
                ? AppColors.primary
                : suspended
                    ? AppColors.error.withValues(alpha: 0.4)
                    : context.borderColor,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: () async {
            if (selectMode) {
              onToggleSelect?.call(user.id);
              return;
            }
            final changed = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) => SuperAdminUserDetailScreen(user: user),
              ),
            );
            if (changed == true) onChanged?.call();
          },
          onLongPress: () {
            if (!selectMode) {
              onLongPressSelect?.call(user.id);
            }
          },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                if (selectMode)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) => onToggleSelect?.call(user.id),
                      activeColor: AppColors.primary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                else
                  CircleAvatar(
                    radius: 20,
                    backgroundColor:
                        (isStudio ? AppColors.primary : AppColors.accent).withValues(alpha: 0.12),
                    child: Text(user.initials,
                        style: TextStyle(
                            color: isStudio ? AppColors.primary : AppColors.accent,
                            fontWeight: FontWeight.w700)),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(user.fullName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 13.5)),
                          ),
                        ],
                      ),
                      Text(
                        '${isStudio ? (user.studioName ?? user.email) : user.email} • ${formatBytes(storageBytes)}',
                        style: TextStyle(
                            fontSize: 11.5, color: context.textMuted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (suspended)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: const Text('Suspended',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: AppColors.error)),
                  )
                else if (isStudio)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: user.subscriptionStatus.subscriptionColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(user.subscriptionStatus.subscriptionLabel,
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: user.subscriptionStatus.subscriptionColor)),
                  )
                else
                  Icon(Icons.chevron_right_rounded, color: context.textMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyList extends StatelessWidget {
  final String label;
  const _EmptyList({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(label, style: TextStyle(color: context.textMuted)),
    );
  }
}