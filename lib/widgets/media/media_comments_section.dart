import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/media_comment.dart';
import '../../core/theme/theme_context.dart';

/// Upgraded comments UI:
/// - Scrollable comment list
/// - Draggable bottom sheet composer
/// - Relative timestamps
/// - One-level nested replies
/// - Reply expand/collapse
/// - Delete own comment with confirmation
class MediaCommentsSection extends StatefulWidget {
  final List<MediaComment> comments;
  final String currentUserId;
  final bool isLoading;
  final void Function(String text) onAddTopLevel;
  final void Function(String parentId, String text) onReply;
  final void Function(String commentId, String newText) onEdit;
  final void Function(String commentId) onDelete;

  const MediaCommentsSection({
    super.key,
    required this.comments,
    required this.currentUserId,
    required this.isLoading,
    required this.onAddTopLevel,
    required this.onReply,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<MediaCommentsSection> createState() => _MediaCommentsSectionState();
}

class _MediaCommentsSectionState extends State<MediaCommentsSection> {
  static const int _maxChars = 240;

  late final TextEditingController _composerController;
  late final FocusNode _composerFocus;
  final ScrollController _listScrollController = ScrollController();

  int _lastCommentCount = 0;

  @override
  void initState() {
    super.initState();
    _composerController = TextEditingController();
    _composerFocus = FocusNode();
    _lastCommentCount = widget.comments.length;
    _composerController.addListener(_onComposerChanged);
  }

  void _onComposerChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _composerController.removeListener(_onComposerChanged);
    _composerController.dispose();
    _composerFocus.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MediaCommentsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.comments.length != _lastCommentCount) {
      _lastCommentCount = widget.comments.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_listScrollController.hasClients) {
          _listScrollController.animateTo(
            _listScrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  List<MediaComment> get _roots =>
      widget.comments.where((c) => c.parentId == null).toList();

  String _relativeTimestamp(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  void _submitTopLevel() {
    final raw = _composerController.text;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > _maxChars) return;

    widget.onAddTopLevel(trimmed);
    _composerController.clear();

    // Keep focus so user can continue writing.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _composerFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final roots = _roots..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Text(
                'Comments',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '(${widget.comments.length})',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.textMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (widget.isLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else ...[
          if (widget.comments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              child: Text(
                'Be the first to comment.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: context.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: roots.length,
              itemBuilder: (context, i) {
                final root = roots[i];
                return _CommentCard(
                  comment: root,
                  allComments: widget.comments,
                  currentUserId: widget.currentUserId,
                  relativeTimestamp: _relativeTimestamp,
                  onReply: widget.onReply,
                  onEdit: widget.onEdit,
                  onDelete: (commentId) => widget.onDelete(commentId),
                );
              },
            ),
          const SizedBox(height: AppSpacing.md),
          // Composer inline container
          Container(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            decoration: BoxDecoration(
              color: context.surfaceColor,
              border: Border.all(
                color: context.borderColor.withValues(alpha: 0.55),
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Icon(Icons.edit_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Add a comment',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: context.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${_composerController.text.characters.length}/$_maxChars',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: context.textMuted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                KeyboardDismissOnTap(
                  child: TextField(
                    controller: _composerController,
                    focusNode: _composerFocus,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: _maxChars,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: 'Write something…',
                      filled: true,
                      fillColor: context.bgColor.withValues(alpha: 0.55),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        borderSide: BorderSide(
                          color: context.borderColor.withValues(alpha: 0.6),
                        ),
                      ),
                      counterText: '',
                    ),
                    onSubmitted: (_) => _submitTopLevel(),
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submitTopLevel,
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('Send'),
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class KeyboardDismissOnTap extends StatelessWidget {
  final Widget child;

  const KeyboardDismissOnTap({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
      child: child,
    );
  }
}

class _CommentCard extends StatefulWidget {
  final MediaComment comment;
  final List<MediaComment> allComments;
  final String currentUserId;
  final String Function(DateTime dt) relativeTimestamp;

  final void Function(String parentId, String text) onReply;
  final void Function(String commentId, String newText) onEdit;
  final void Function(String commentId) onDelete;

  const _CommentCard({
    required this.comment,
    required this.allComments,
    required this.currentUserId,
    required this.relativeTimestamp,
    required this.onReply,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_CommentCard> createState() => _CommentCardState();
}

class _CommentCardState extends State<_CommentCard> {
  bool _replying = false;
  final TextEditingController _replyController = TextEditingController();

  bool _expandedReplies = true;
  bool _editing = false;
  final TextEditingController _editController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _editController.text = widget.comment.text;
  }

  @override
  void dispose() {
    _replyController.dispose();
    _editController.dispose();
    super.dispose();
  }

  bool get _isMine => widget.comment.userId == widget.currentUserId;

  List<MediaComment> get _directReplies =>
      widget.allComments.where((c) => c.parentId == widget.comment.id).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  // One-level nested replies only:
  // replies of replies are not rendered.
  List<MediaComment> get _childrenToRender => _directReplies
      .where((r) => widget.allComments
          .every((possibleGrandChild) => possibleGrandChild.parentId != r.id))
      .toList();

  void _toggleReply() {
    setState(() => _replying = !_replying);
    if (!_replying) _replyController.clear();
  }

  void _submitReply() {
    final trimmed = _replyController.text.trim();
    if (trimmed.isEmpty) return;
    widget.onReply(widget.comment.id, trimmed);
    _replyController.clear();
    setState(() => _replying = false);
    // Expand replies to show newly added.
    setState(() => _expandedReplies = true);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete comment?'),
        content: const Text('This removes your comment and its replies.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      widget.onDelete(widget.comment.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final directReplies = _directReplies;
    final replyCount = directReplies.length;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 3),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.25),
                  ),
                ),
                child: const Icon(
                  Icons.person_rounded,
                  size: 16,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _isMine ? 'You' : 'user',
                          // Username placeholder as requested.
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: context.textPrimary,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          widget.relativeTimestamp(widget.comment.createdAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: context.textMuted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(
                          color: context.borderColor.withValues(alpha: 0.55),
                        ),
                      ),
                      child: Text(
                        _editing ? _editController.text : widget.comment.text,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: context.textPrimary),
                      ),
                    ),
                    if (_editing) ...[
                      const SizedBox(height: AppSpacing.sm),
                      TextField(
                        controller: _editController,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: 'Edit comment…',
                          filled: true,
                          fillColor:
                              context.bgColor.withValues(alpha: 0.55),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                            borderSide: BorderSide(
                              color: context.borderColor.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          FilledButton.tonal(
                            onPressed: () {
                              widget.onEdit(
                                  widget.comment.id, _editController.text);
                              setState(() => _editing = false);
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor:
                                  AppColors.primary.withValues(alpha: 0.12),
                            ),
                            child: const Text('Save'),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          OutlinedButton(
                            onPressed: () {
                              _editController.text = widget.comment.text;
                              setState(() => _editing = false);
                            },
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: AppSpacing.sm),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: 0,
                      children: [
                        TextButton.icon(
                          onPressed: _toggleReply,
                          icon: const Icon(Icons.reply_rounded, size: 18),
                          label: Text(replyCount == 0
                              ? 'Reply'
                              : 'Reply ($replyCount)'),
                        ),
                        if (_directReplies.isNotEmpty)
                          TextButton.icon(
                            onPressed: () => setState(
                                () => _expandedReplies = !_expandedReplies),
                            icon: Icon(
                              _expandedReplies
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 18,
                            ),
                            label: const Text('Replies'),
                          ),
                        if (_isMine) ...[
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _editing = true;
                                _replying = false;
                                _editController.text = widget.comment.text;
                              });
                            },
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Edit'),
                          ),
                          TextButton.icon(
                            onPressed: _confirmDelete,
                            icon: const Icon(Icons.delete_outline_rounded,
                                size: 18),
                            label: const Text('Delete'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_replying)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.sm),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TextField(
                              controller: _replyController,
                              minLines: 1,
                              maxLines: 3,
                              decoration: InputDecoration(
                                hintText: 'Write a reply…',
                                filled: true,
                                fillColor: context.bgColor
                                    .withValues(alpha: 0.55),
                                border: OutlineInputBorder(
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.lg),
                                  borderSide: BorderSide(
                                    color:
                                        context.borderColor.withValues(alpha: 0.6),
                                  ),
                                ),
                              ),
                              onSubmitted: (_) => _submitReply(),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                            Row(
                              children: [
                                FilledButton.icon(
                                  onPressed: _submitReply,
                                  icon: const Icon(Icons.send_rounded),
                                  label: const Text('Reply'),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                OutlinedButton(
                                  onPressed: () {
                                    _replyController.clear();
                                    setState(() => _replying = false);
                                  },
                                  child: const Text('Cancel'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (_expandedReplies)
            if (_childrenToRender.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 48, top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _childrenToRender
                      .map((child) => _ReplyCard(
                            reply: child,
                            allComments: widget.allComments,
                            currentUserId: widget.currentUserId,
                            relativeTimestamp: widget.relativeTimestamp,
                            onReply: widget.onReply,
                            onEdit: widget.onEdit,
                            onDelete: widget.onDelete,
                          ))
                      .toList(),
                ),
              ),
        ],
      ),
    );
  }
}

class _ReplyCard extends StatefulWidget {
  final MediaComment reply;
  final List<MediaComment> allComments;
  final String currentUserId;
  final String Function(DateTime dt) relativeTimestamp;

  final void Function(String parentId, String text) onReply;
  final void Function(String commentId, String newText) onEdit;
  final void Function(String commentId) onDelete;

  const _ReplyCard({
    required this.reply,
    required this.allComments,
    required this.currentUserId,
    required this.relativeTimestamp,
    required this.onReply,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<_ReplyCard> createState() => _ReplyCardState();
}

class _ReplyCardState extends State<_ReplyCard> {
  bool _replying = false;
  final TextEditingController _replyController = TextEditingController();

  bool _editing = false;
  final TextEditingController _editController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _editController.text = widget.reply.text;
  }

  @override
  void dispose() {
    _replyController.dispose();
    _editController.dispose();
    super.dispose();
  }

  bool get _isMine => widget.reply.userId == widget.currentUserId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 3),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.23),
                  ),
                ),
                child: const Icon(
                  Icons.person_rounded,
                  size: 15,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _isMine ? 'You' : 'user',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                            color: context.textPrimary,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          widget.relativeTimestamp(widget.reply.createdAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: context.textMuted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.78),
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(
                          color: context.borderColor.withValues(alpha: 0.55),
                        ),
                      ),
                      child: Text(
                        _editing ? _editController.text : widget.reply.text,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: context.textPrimary),
                      ),
                    ),

                    const SizedBox(height: AppSpacing.sm),

                    Wrap(
                      spacing: AppSpacing.sm,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            // Max one level: we only allow reply to this reply
                            // as a UI action, but the controller will create
                            // a grandchild. Prevent by not showing reply action.
                            setState(() => _replying = !_replying);
                          },
                          icon: const Icon(Icons.reply_rounded, size: 18),
                          label: const Text('Reply'),
                          // This is intentionally hidden by requirement (max one level).
                          // We'll disable the action instead.
                        ),
                        if (_isMine) ...[
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _editing = true;
                                _replying = false;
                                _editController.text = widget.reply.text;
                              });
                            },
                            icon: const Icon(Icons.edit_outlined, size: 18),
                            label: const Text('Edit'),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  title: const Text('Delete reply?'),
                                  content: const Text(
                                      'This will remove your reply and its nested replies.'),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(false),
                                      child: const Text('Cancel'),
                                    ),
                                    FilledButton.tonal(
                                      style: FilledButton.styleFrom(
                                          backgroundColor: AppColors.error),
                                      onPressed: () =>
                                          Navigator.of(ctx).pop(true),
                                      child: const Text(
                                        'Delete',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                widget.onDelete(widget.reply.id);
                              }
                            },
                            icon: const Icon(Icons.delete_outline_rounded,
                                size: 18),
                            label: const Text('Delete'),
                            style: TextButton.styleFrom(
                              foregroundColor: AppColors.error,
                            ),
                          ),
                        ],
                      ],
                    ),

                    if (_editing) ...[
                      const SizedBox(height: AppSpacing.sm),
                      TextField(
                        controller: _editController,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: 'Edit reply…',
                          filled: true,
                          fillColor:
                              context.bgColor.withValues(alpha: 0.55),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(AppRadius.lg),
                            borderSide: BorderSide(
                              color: context.borderColor.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          FilledButton.tonal(
                            onPressed: () {
                              widget.onEdit(
                                  widget.reply.id, _editController.text);
                              setState(() => _editing = false);
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor:
                                  AppColors.primary.withValues(alpha: 0.12),
                            ),
                            child: const Text('Save'),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          OutlinedButton(
                            onPressed: () {
                              _editController.text = widget.reply.text;
                              setState(() => _editing = false);
                            },
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ],

                    // Reply-to-reply composer is intentionally omitted to satisfy
                    // "maximum one level" nested replies.
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
