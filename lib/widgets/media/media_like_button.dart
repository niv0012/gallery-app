import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_context.dart';

class MediaLikeButton extends StatefulWidget {
  final bool liked;
  final int likeCount;
  final VoidCallback onToggle;

  const MediaLikeButton({
    super.key,
    required this.liked,
    required this.likeCount,
    required this.onToggle,
  });

  @override
  State<MediaLikeButton> createState() => _MediaLikeButtonState();
}

class _MediaLikeButtonState extends State<MediaLikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scaleController;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 120),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
        CurvedAnimation(parent: _scaleController, curve: Curves.easeOut));

    if (widget.liked) {
      _scaleController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MediaLikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.liked != widget.liked) {
      _scaleController.forward(from: 0).then((_) {
        if (mounted) _scaleController.reverse();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final liked = widget.liked;
    final iconColor = liked ? AppColors.accent : context.textMuted;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: widget.onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ScaleTransition(
                scale: _scaleAnimation,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 170),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.95, end: 1.0)
                            .animate(animation),
                        child: child,
                      ),
                    );
                  },
                  layoutBuilder: (currentChild, previousChildren) {
                    return currentChild ?? const SizedBox.shrink();
                  },
                  child: Icon(
                    key: ValueKey<bool>(liked),
                    liked
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    color: iconColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 180),
                style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                      color: context.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                child: Text('${widget.likeCount}'),
              ),
              const SizedBox(width: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 170),
                child: Text(
                  key: ValueKey<String>(liked ? 'liked' : 'like'),
                  liked ? 'Liked' : 'Like',
                  style: Theme.of(context).textTheme.bodySmall!.copyWith(
                        color: context.textMuted,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
