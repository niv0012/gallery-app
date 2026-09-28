import 'package:flutter/material.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/server_config_storage.dart';
import '../buttons/gradient_button.dart';
import '../inputs/custom_text_field.dart';
import '../../core/theme/theme_context.dart';

/// Dev-facing "change the backend host without editing code" sheet.
/// Opened from the small gear icon on [SplashScreen]. Saving:
/// 1. Updates the live [ApiClient.baseUrl] immediately — no restart
///    needed for the rest of this session.
/// 2. Persists the host via [ServerConfigStorage] so future launches
///    pick it up too (see `main.dart`).
class ServerSettingsSheet extends StatefulWidget {
  final ApiClient apiClient;
  const ServerSettingsSheet({super.key, required this.apiClient});

  static Future<void> show(BuildContext context, ApiClient apiClient) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ServerSettingsSheet(apiClient: apiClient),
    );
  }

  @override
  State<ServerSettingsSheet> createState() => _ServerSettingsSheetState();
}

class _ServerSettingsSheetState extends State<ServerSettingsSheet> {
  late final TextEditingController _hostController =
      TextEditingController(text: _extractHost(widget.apiClient));
  bool _saving = false;

  /// Pulls the value back out of a full base URL so the field starts
  /// prefilled with whatever's active now:
  /// - Nothing configured yet ([ApiClient.isConfigured] is false): empty,
  ///   so the hint text shows instead of a confusing sentinel string.
  /// - The default `http://host:8000/api/v1` shape: just the bare
  ///   host/IP, matching what a dev normally types here.
  /// - Anything else (a tunnel URL with its own scheme/port, e.g.
  ///   `https://my-tunnel.trycloudflare.com`): the full URL, verbatim —
  ///   reducing it to just `uri.host` would silently drop the `https://`
  ///   and non-default port, breaking it the moment it's saved again.
  static String _extractHost(ApiClient apiClient) {
    if (apiClient.baseUrl.isEmpty) return '';
    final baseUrl = apiClient.baseUrl;
    final uri = Uri.tryParse(baseUrl);
    if (uri != null && uri.scheme == 'http' && uri.port == 8000) {
      return uri.host;
    }
    return baseUrl.endsWith('/api/v1')
        ? baseUrl.substring(0, baseUrl.length - '/api/v1'.length)
        : baseUrl;
  }

  Future<void> _save() async {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;

    setState(() => _saving = true);
    widget.apiClient.updateBaseUrl(ApiClient.baseUrlForHost(host));
    await ServerConfigStorage().saveHost(host);
    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).clearSnackBars();
  }

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xl),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                decoration: BoxDecoration(
                    color: context.borderColor,
                    borderRadius: BorderRadius.circular(4)),
              ),
            ),
            Text('Server Settings',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              "Point the app at your backend: either your PC's LAN IP (find it with "
              '`ipconfig` on Windows or `ifconfig` on Mac/Linux — only works on the same '
              "Wi-Fi), or a persistent tunnel URL (e.g. from ngrok or Cloudflare Tunnel) "
              'so it works from any network, including mobile data. No code edit or rebuild needed.',
              style:
                  Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: AppSpacing.lg),
            CustomTextField(
              label: 'Server IP, host, or tunnel URL',
              hint: 'e.g. 172.20.10.4 or https://my-tunnel.trycloudflare.com',
              icon: Icons.dns_outlined,
              controller: _hostController,
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: AppSpacing.lg),
            GradientButton(
                label: 'Save & Use Now', isLoading: _saving, onPressed: _save),
          ],
        ),
      ),
    );
  }
}
