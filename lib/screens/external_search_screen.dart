import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../components/now_playing_bar.dart';
import '../models/external_search_query.dart';

/// Form for searching a song, artist, and/or album on an external catalog.
///
/// API wiring to a non-Jellyfin server will consume [ExternalSearchQuery].
class ExternalSearchScreen extends StatefulWidget {
  const ExternalSearchScreen({Key? key}) : super(key: key);

  static const routeName = "/external-search";

  @override
  State<ExternalSearchScreen> createState() => _ExternalSearchScreenState();
}

class _ExternalSearchScreenState extends State<ExternalSearchScreen> {
  final _songController = TextEditingController();
  final _artistController = TextEditingController();
  final _albumController = TextEditingController();

  bool get _canSearch {
    return _songController.text.trim().isNotEmpty ||
        _artistController.text.trim().isNotEmpty ||
        _albumController.text.trim().isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _songController.addListener(_onFieldChanged);
    _artistController.addListener(_onFieldChanged);
    _albumController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _songController.removeListener(_onFieldChanged);
    _artistController.removeListener(_onFieldChanged);
    _albumController.removeListener(_onFieldChanged);
    _songController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
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
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _onCancel,
                    child: Text(
                      MaterialLocalizations.of(context).cancelButtonLabel,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _canSearch ? _onSearch : null,
                    child: Text(localizations.searchButtonLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
