import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/chat_message_model.dart';
import '../../providers/auth_providers.dart';
import '../../providers/chat_provider.dart';
import '../../widgets/common/custom_app_bar.dart';
import '../../widgets/common/screen_backdrop.dart';
import '../../core/theme/theme_context.dart';

/// Screen for a single chat thread. Takes either a `threadId` or a
/// `connectionId` via route arguments (the [ChatNotifier] handles both).
///
/// Route arguments: `Map` with keys `threadId`, `connectionId`,
/// `otherPartyName`, `otherPartyAvatar`.
class ChatThreadScreen extends ConsumerStatefulWidget {
  final String threadId;
  final String connectionId;
  final String otherPartyName;
  final String? otherPartyAvatar;

  const ChatThreadScreen({
    super.key,
    required this.threadId,
    required this.connectionId,
    required this.otherPartyName,
    this.otherPartyAvatar,
  });

  @override
  ConsumerState<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends ConsumerState<ChatThreadScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    final notifier = ref.read(chatProvider.notifier);
    Future.microtask(() async {
      // Fetch messages for this thread
      await notifier.loadMessages(widget.threadId);
      notifier.markAsRead(widget.threadId);
      if (mounted) {
        setState(() => _isLoading = false);
        _scrollToBottom();
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _handleSend() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    _textController.clear();

    await ref.read(chatProvider.notifier).sendMessageByConnection(
          widget.connectionId,
          text,
        );

    ref.read(chatProvider.notifier).markAsRead(widget.threadId);
    Future.delayed(const Duration(milliseconds: 100), _scrollToBottom);
  }

  @override
  Widget build(BuildContext context) {
    final chatState = ref.watch(chatProvider);
    final threadMsgs = chatState.messagesForThread(widget.threadId);

    // Mark as read on every rebuild (polling may have brought new msgs)
    Future.microtask(
        () => ref.read(chatProvider.notifier).markAsRead(widget.threadId));

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: CustomAppBar(
        title: widget.otherPartyName,
        showBack: true,
      ),
      body: ScreenBackdrop(
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.only(top: kToolbarHeight),
            child: Column(
              children: [
                Expanded(
                  child: _isLoading
                      ? Center(child: CircularProgressIndicator())
                      : threadMsgs.isEmpty
                          ? _buildEmptyState()
                          : ListView.builder(
                              controller: _scrollController,
                              padding: EdgeInsets.symmetric(
                                  horizontal: AppSpacing.md, vertical: 16),
                              itemCount: threadMsgs.length,
                              itemBuilder: (context, index) {
                                final msg = threadMsgs[index];
                                final currentUserId =
                                    ref.read(authStateProvider).user?.id ?? '';
                                final isMe = msg.senderId == currentUserId;

                                return _buildMessageBubble(msg, isMe);
                              },
                            ),
                ),
                _buildInputArea(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline_rounded,
            size: 48,
            color: context.textMuted.withValues(alpha: 0.5),
          ),
          SizedBox(height: 16),
          Text(
            'Start the Conversation',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Type a message below to chat with the studio.',
            style: TextStyle(
              fontSize: 13,
              color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessageModel msg, bool isMe) {
    final timeStr = DateFormat('h:mm a').format(msg.sentAt.toLocal());

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isMe
                    ? AppColors.primary
                    : (Theme.of(context).brightness == Brightness.dark
                        ? AppColors.darkSurface
                        : Colors.white),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
                border: isMe
                    ? null
                    : Border.all(color: context.borderColor, width: 0.8),
              ),
              child: Text(
                msg.text,
                style: TextStyle(
                  color: isMe ? Colors.white : (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text),
                  fontSize: 14.5,
                  height: 1.4,
                ),
              ),
            ),
            SizedBox(height: 4),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                timeStr,
                style: TextStyle(
                  fontSize: 10,
                  color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkBackground
            : Colors.white.withValues(alpha: 0.95),
        border: Border(
          top: BorderSide(color: context.borderColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(color: (Theme.of(context).brightness == Brightness.dark ? AppColors.textOnDark : AppColors.text), fontSize: 14.5),
              decoration: InputDecoration(
                hintText: 'Type your message...',
                hintStyle:
                    TextStyle(color: (Theme.of(context).brightness == Brightness.dark ? AppColors.subtitleOnDark : AppColors.subtitle), fontSize: 14.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: context.borderColor),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: context.borderColor),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide:
                      const BorderSide(color: AppColors.primary, width: 1.5),
                ),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                fillColor: context.bgColor.withValues(alpha: 0.5),
                filled: true,
              ),
            ),
          ),
          SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
              gradient: AppColors.heroGradient,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: Icon(Icons.send_rounded, color: Colors.white),
              onPressed: _handleSend,
            ),
          ),
        ],
      ),
    );
  }
}
