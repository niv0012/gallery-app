import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import 'anchored_menu.dart';
import '../../core/theme/theme_context.dart';

/// A compact, borderless "label + caret" dropdown trigger (matching the
/// look of Flutter's [DropdownButton] with its underline hidden) whose
/// popup is opened via [AnchoredMenu] instead of Flutter's built-in
/// [DropdownButton] menu route.
///
/// [DropdownButton]'s own menu positions itself so the *currently selected*
/// item lines up with the button, rather than opening the list directly
/// below the button. In a dense, horizontally-scrolling toolbar (several
/// of these sitting side by side) that makes the popup land on top of
/// neighbouring controls instead of underneath the one that was tapped.
/// [CompactAnchoredDropdown] keeps the exact same compact visuals but
/// anchors the popup correctly below (or above, if there isn't room)
/// the trigger that opened it.
class CompactAnchoredDropdown<T> extends StatefulWidget {
  const CompactAnchoredDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.style,
    this.iconSize = 16,
    this.menuWidth,
    this.maxMenuHeight = 280,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T> onChanged;
  final TextStyle? style;
  final double iconSize;

  /// Defaults to the trigger's own width, same as before.
  final double? menuWidth;
  final double maxMenuHeight;

  @override
  State<CompactAnchoredDropdown<T>> createState() =>
      _CompactAnchoredDropdownState<T>();
}

class _CompactAnchoredDropdownState<T>
    extends State<CompactAnchoredDropdown<T>> {
  final AnchoredMenuController _controller = AnchoredMenuController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onMenuStateChanged);
  }

  void _onMenuStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onMenuStateChanged);
    _controller.dispose();
    super.dispose();
  }

  Widget _buildMenu(BuildContext context, VoidCallback close) {
    return Material(
      elevation: 8,
      color: context.surfaceColor,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 4),
        children: widget.items.map((item) {
          final selected = item.value == widget.value;
          return InkWell(
            onTap: () {
              close();
              widget.onChanged(item.value as T);
            },
            child: Container(
              color:
                  selected ? AppColors.primary.withValues(alpha: 0.08) : null,
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: 12),
              child: DefaultTextStyle.merge(
                style: (widget.style ?? const TextStyle()).copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppColors.primary : context.textPrimary,
                ),
                child: item.child,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final matches = widget.items.where((i) => i.value == widget.value);
    final display = matches.isNotEmpty ? matches.first.child : null;

    return AnchoredMenu(
      controller: _controller,
      menuWidth: widget.menuWidth,
      maxMenuHeight: widget.maxMenuHeight,
      menuBuilder: _buildMenu,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: _controller.toggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (display != null)
                Flexible(child: DefaultTextStyle.merge(style: widget.style, child: display)),
              Icon(
                _controller.isOpen
                    ? Icons.arrow_drop_up_rounded
                    : Icons.arrow_drop_down_rounded,
                size: widget.iconSize + 4,
                color: widget.style?.color ?? context.textPrimary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
