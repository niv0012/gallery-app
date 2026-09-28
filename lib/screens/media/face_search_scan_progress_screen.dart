import 'package:image_picker/image_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/routes/app_routes.dart';
import '../../core/theme/app_theme.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../providers/face_search_provider.dart';
import '../../core/theme/theme_context.dart';

class FaceSearchScanProgressScreen extends ConsumerStatefulWidget {
  final XFile file;

  const FaceSearchScanProgressScreen({super.key, required this.file});

  @override
  ConsumerState<FaceSearchScanProgressScreen> createState() =>
      _FaceSearchScanProgressScreenState();
}

class _FaceSearchScanProgressScreenState
    extends ConsumerState<FaceSearchScanProgressScreen> {
  bool _cancelled = false;
  bool _navigated = false;
  bool _searchStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_searchStarted) {
      _searchStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runSearch();
      });
    }
  }

  Future<void> _runSearch() async {
    final success = await ref
        .read(faceSearchProvider.notifier)
        .selectSelfieFile(widget.file);
    if (!mounted || _cancelled) return;

    if (success) {
      _navigateToResultsOnce();
    }
  }

  void _navigateToResultsOnce() {
    if (_navigated) return;
    _navigated = true;
    Navigator.of(context).pushReplacementNamed(AppRoutes.faceSearchResults);
  }

  void _cancel() {
    if (_cancelled) return;
    setState(() => _cancelled = true);
    Navigator.of(context).pushNamedAndRemoveUntil(
      AppRoutes.faceSearchLanding,
      (r) => r.isFirst,
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(faceSearchProvider);

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {},
      child: Scaffold(
        appBar: CustomAppBar(
          title: 'Scanning…',
          showBack: false,
          actions: [
            IconButton(
              tooltip: 'Cancel scan',
              icon: Icon(Icons.close_rounded),
              onPressed: _cancel,
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildScanCard(state),
                SizedBox(height: AppSpacing.lg),
                if (state.error != null)
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      state.error!,
                      style: TextStyle(color: AppColors.error),
                    ),
                  )
                else
                  Center(child: CircularProgressIndicator()),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScanCard(FaceSearchState state) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildAnimatedScannerIcon(),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.statusMessage,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w900,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.textOnDark
                        : AppColors.text),
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Matching your selfie against shared albums…',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.subtitleOnDark
                        : AppColors.subtitle),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAnimatedScannerIcon() {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Icon(
        Icons.auto_awesome_rounded,
        color: AppColors.primary,
        size: 22,
      ),
    );
  }
}
