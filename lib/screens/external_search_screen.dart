import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../components/now_playing_bar.dart';
import '../models/external_search_query.dart';
import '../services/finamp_settings_helper.dart';
import '../services/music_finder_client.dart';

/// Form for searching a song, artist, and/or album on an external catalog.
///
/// Requires a reachable Music Finder server URL (HTTP 200) before the search
/// fields are shown. A future API client will consume [ExternalSearchQuery].
class ExternalSearchScreen extends StatefulWidget {
  const ExternalSearchScreen({Key? key}) : super(key: key);

  static const routeName = "/external-search";

  @override
  State<ExternalSearchScreen> createState() => _ExternalSearchScreenState();
}

class _ExternalSearchScreenState extends State<ExternalSearchScreen> {
  final _serverUrlController = TextEditingController();
  final _songController = TextEditingController();
  final _artistController = TextEditingController();
  final _albumController = TextEditingController();
  final _musicFinderClient = MusicFinderClient();

  bool _isConnecting = false;
  bool _isConnected = false;
  String? _serverUrlError;

  bool get _canSearch {
    return _isConnected &&
        (_songController.text.trim().isNotEmpty ||
            _artistController.text.trim().isNotEmpty ||
            _albumController.text.trim().isNotEmpty);
  }

  @override
  void initState() {
    super.initState();
    _songController.addListener(_onFieldChanged);
    _artistController.addListener(_onFieldChanged);
    _albumController.addListener(_onFieldChanged);
    _serverUrlController.addListener(_onServerUrlEdited);

    final savedUrl = FinampSettingsHelper.finampSettings.musicFinderServerUrl;
    if (savedUrl != null && savedUrl.isNotEmpty) {
      _serverUrlController.text = savedUrl;
      // Auto-check persisted URL on every open.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _connect();
        }
      });
    }
  }

  void _onFieldChanged() {
    setState(() {});
  }

  void _onServerUrlEdited() {
    if (_isConnected) {
      setState(() {
        _isConnected = false;
        _serverUrlError = null;
      });
    }
  }

  @override
  void dispose() {
    _songController.removeListener(_onFieldChanged);
    _artistController.removeListener(_onFieldChanged);
    _albumController.removeListener(_onFieldChanged);
    _serverUrlController.removeListener(_onServerUrlEdited);
    _serverUrlController.dispose();
    _songController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
  }

  String? _validateServerUrl(String raw) {
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

    final validationError = _validateServerUrl(_serverUrlController.text);
    if (validationError != null) {
      setState(() {
        _serverUrlError = validationError;
        _isConnected = false;
      });
      return;
    }

    final url = _serverUrlController.text.trim();
    setState(() {
      _isConnecting = true;
      _serverUrlError = null;
      _isConnected = false;
    });

    final ok = await _musicFinderClient.checkConnection(url);

    if (!mounted) {
      return;
    }

    setState(() {
      _isConnecting = false;
      _isConnected = ok;
      if (!ok) {
        _serverUrlError =
            AppLocalizations.of(context)!.musicFinderConnectFailed;
      }
    });

    if (ok) {
      FinampSettingsHelper.setMusicFinderServerUrl(url);
    }
  }

  ExternalSearchQuery _buildQuery() {
    String? trimOrNull(String value) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return ExternalSearchQuery(
      song: trimOrNull(_songController.text),
      artist: trimOrNull(_artistController.text),
      album: trimOrNull(_albumController.text),
    );
  }

  void _onCancel() {
    Navigator.of(context).pop();
  }

  void _onSearch() {
    if (!_canSearch) {
      return;
    }

    final localizations = AppLocalizations.of(context)!;
    final query = _buildQuery();
    final criteria = query.toCriteriaSummary(
      songLabel: localizations.song,
      artistLabel: localizations.artist,
      albumLabel: localizations.album,
    );
    final messenger = ScaffoldMessenger.of(context);
    final message = localizations.externalSearchSubmitted(criteria);

    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final node = FocusScope.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.externalSearch),
      ),
      bottomNavigationBar: const NowPlayingBar(),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _serverUrlController,
                enabled: !_isConnecting,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onEditingComplete: () => _connect(),
                decoration: InputDecoration(
                  labelText: localizations.musicFinderServerUrl,
                  hintText: "http://0.0.0.0:8080",
                  border: const OutlineInputBorder(),
                  errorText: _serverUrlError,
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: _isConnecting ? null : _connect,
                  child: Text(
                    _isConnecting
                        ? localizations.connectingButtonLabel
                        : localizations.connectButtonLabel,
                  ),
                ),
              ),
              if (_isConnected) ...[
                const SizedBox(height: 24),
                TextField(
                  controller: _songController,
                  textInputAction: TextInputAction.next,
                  onEditingComplete: () => node.nextFocus(),
                  decoration: InputDecoration(
                    labelText: localizations.song,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _artistController,
                  textInputAction: TextInputAction.next,
                  onEditingComplete: () => node.nextFocus(),
                  decoration: InputDecoration(
                    labelText: localizations.artist,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _albumController,
                  textInputAction: TextInputAction.done,
                  onEditingComplete: _canSearch ? _onSearch : null,
                  decoration: InputDecoration(
                    labelText: localizations.album,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isConnecting ? null : _onCancel,
                    child: Text(
                      MaterialLocalizations.of(context).cancelButtonLabel,
                    ),
                  ),
                  if (_isConnected) ...[
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _canSearch ? _onSearch : null,
                      child: Text(localizations.searchButtonLabel),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
