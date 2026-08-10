import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../../services/music_finder_client.dart';

/// Modal sheet to enter and health-check a Music Finder base URL.
///
/// Pops with the connected URL on success, or `null` if dismissed.
class MusicFinderServerSheet extends StatefulWidget {
  const MusicFinderServerSheet({
    Key? key,
    required this.client,
    this.initialUrl,
    this.autoConnect = false,
  }) : super(key: key);

  final MusicFinderClient client;
  final String? initialUrl;

  /// When true and [initialUrl] is non-empty, run Connect once the sheet opens.
  final bool autoConnect;

  static Future<String?> show(
    BuildContext context, {
    required MusicFinderClient client,
    String? initialUrl,
    bool autoConnect = false,
    bool isDismissible = true,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      isDismissible: isDismissible,
      enableDrag: isDismissible,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.0)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: MusicFinderServerSheet(
            client: client,
            initialUrl: initialUrl,
            autoConnect: autoConnect,
          ),
        );
      },
    );
  }

  @override
  State<MusicFinderServerSheet> createState() => _MusicFinderServerSheetState();
}

class _MusicFinderServerSheetState extends State<MusicFinderServerSheet> {
  late final TextEditingController _urlController;
  bool _isConnecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.initialUrl ?? "");
    if (widget.autoConnect && (_urlController.text.trim().isNotEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _connect();
        }
      });
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String? _validate(String raw) {
    final localizations = AppLocalizations.of(context)!;
    final value = raw.trim();
    if (value.isEmpty) {
      return localizations.emptyServerUrl;
    }
    if (!value.startsWith("http://") && !value.startsWith("https://")) {
      return localizations.urlStartWithHttps;
    }
    if (value.endsWith("/")) {
      return localizations.urlTrailingSlash;
    }
    return null;
  }

  Future<void> _connect() async {
    if (_isConnecting) {
      return;
    }

    final validationError = _validate(_urlController.text);
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }

    final url = _urlController.text.trim();
    setState(() {
      _isConnecting = true;
      _error = null;
    });

    final ok = await widget.client.checkConnection(url);
    if (!mounted) {
      return;
    }

    if (ok) {
      Navigator.of(context, rootNavigator: true).pop(url);
      return;
    }

    setState(() {
      _isConnecting = false;
      _error = AppLocalizations.of(context)!.musicFinderConnectFailed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Text(
              localizations.musicFinderServerSheetTitle,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              localizations.musicFinderServerSheetSubtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              enabled: !_isConnecting,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              onEditingComplete: _connect,
              decoration: InputDecoration(
                labelText: localizations.musicFinderServerUrl,
                hintText: "http://downloads.local:8088",
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _isConnecting
                      ? null
                      : () => Navigator.of(context, rootNavigator: true).pop(),
                  child: Text(
                    MaterialLocalizations.of(context).cancelButtonLabel,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isConnecting ? null : _connect,
                  child: _isConnecting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(localizations.connectButtonLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
