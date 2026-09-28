import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/settings_provider.dart';
import '../../../widgets/common/custom_app_bar.dart';
import '../../../widgets/inputs/custom_text_field.dart';
import '../../../services/media_picker_service.dart';
import '../../../core/theme/theme_context.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _nameController;
  late TextEditingController _emailController;

  Uint8List? _avatarBytes;

  Future<void> _pickAvatar() async {
    final picker = MediaPickerService();
    final files = await picker.pickPhotos(allowMultiple: false);
    if (files.isNotEmpty) {
      setState(() {
        _avatarBytes = Uint8List.fromList(files.first.bytes);
      });
    }
  }

  @override
  void initState() {
    super.initState();

    final settings = ref.read(settingsProvider);
    _nameController = TextEditingController(text: settings.photographerName);
    _emailController = TextEditingController(text: settings.email);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: const CustomAppBar(
        title: 'Edit Profile',
        showBack: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(AppSpacing.lg),
          children: [
            _ProfilePhotoTile(
              avatarBytes: _avatarBytes,
              onEdit: _pickAvatar,
            ),
            SizedBox(height: AppSpacing.lg),
            Form(
              key: _formKey,
              child: Column(
                children: [
                  CustomTextField(
                    label: 'Name',
                    icon: Icons.person_outline_rounded,
                    controller: _nameController,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Name is required';
                      }
                      return null;
                    },
                  ),
                  SizedBox(height: AppSpacing.md),
                  CustomTextField(
                    label: 'Email',
                    icon: Icons.email_outlined,
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) {
                        return 'Email is required';
                      }
                      if (!v.contains('@')) return 'Enter a valid email';
                      return null;
                    },
                  ),
                  SizedBox(height: AppSpacing.xl),
                  FilledButton.icon(
                    icon: Icon(Icons.save_rounded),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: () async {
                      final ok = _formKey.currentState?.validate() ?? false;
                      if (!ok) return;

                      // Persist only what SettingsModel supports for now.
                      await ref.read(settingsProvider.notifier).updateSettings(
                            settings.copyWith(
                              photographerName: _nameController.text.trim(),
                              email: _emailController.text.trim(),
                            ),
                          );

                      if (!context.mounted) return;
                      Navigator.of(context).pop();
                    },
                    label: Text('Save Changes'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfilePhotoTile extends StatelessWidget {
  final Uint8List? avatarBytes;
  final VoidCallback onEdit;

  const _ProfilePhotoTile({this.avatarBytes, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppColors.darkSurface
            : Colors.white,
        border: Border.all(color: context.borderColor),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: avatarBytes == null ? AppColors.heroGradient : null,
              image: avatarBytes != null
                  ? DecorationImage(
                      image: MemoryImage(avatarBytes!),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: avatarBytes == null
                ? Icon(Icons.person_rounded,
                    color: Colors.white, size: 28)
                : null,
          ),
          SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Profile Photo',
                    style: Theme.of(context).textTheme.titleLarge),
                SizedBox(height: 4),
                Text(
                  avatarBytes != null ? 'Photo selected' : 'No photo uploaded',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onEdit,
            icon: Icon(Icons.edit_outlined),
          )
        ],
      ),
    );
  }
}
