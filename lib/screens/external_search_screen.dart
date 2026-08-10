import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';

import '../components/ExternalSearch/music_finder_server_sheet.dart';
import '../components/now_playing_bar.dart';
import '../models/music_finder_models.dart';
import '../services/finamp_settings_helper.dart';
import '../services/music_finder_client.dart';

/// External Music Finder search — mirrors downloads.local music-search UI.
///
/// Server URL entry lives in a modal bottom sheet. A stored URL restores the
/// search UI immediately and is re-checked in the background; the sheet only
/// appears when there is no URL or the host is unreachable.
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
  final _musicFinderClient = MusicFinderClient();

  String? _serverUrl;
  bool _isConnecting = false;
  bool _isConnected = false;
  bool _isSearching = false;
  bool _isAdding = false;
  bool _serverSheetOpen = false;
  String? _searchError;
  String? _selectedArtistId;

  MusicFinderSearchResult? _result;
  MusicFinderAddResult? _addResult;
  final Set<String> _selectedMagnets = {};

  String get _baseUrl => _serverUrl?.trim() ?? "";

  bool get _canSearch {
    return _isConnected &&
        !_isSearching &&
        (_songController.text.trim().isNotEmpty ||
            _artistController.text.trim().isNotEmpty ||
            _albumController.text.trim().isNotEmpty);
  }

  bool get _canAdd =>
      _isConnected && !_isAdding && _selectedMagnets.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _songController.addListener(_onFieldChanged);
    _artistController.addListener(_onFieldChanged);
    _albumController.addListener(_onFieldChanged);

    final savedUrl = FinampSettingsHelper.finampSettings.musicFinderServerUrl;
    if (savedUrl != null && savedUrl.isNotEmpty) {
      // Optimistic: show search immediately with the saved URL; verify in
      // background. Cold starts were stuck on the connect sheet whenever the
      // first probe raced or failed even though the host was fine.
      _serverUrl = savedUrl;
      _isConnected = true;
      _isConnecting = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _verifySavedServer(savedUrl);
        }
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _openServerSheet(force: true);
        }
      });
    }
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

  Future<void> _verifySavedServer(String url) async {
    final ok = await _musicFinderClient.checkConnection(url);
    if (!mounted) {
      return;
    }

    if (ok) {
      setState(() {
        _isConnecting = false;
        _isConnected = true;
        _serverUrl = url;
      });
      FinampSettingsHelper.setMusicFinderServerUrl(url);
      return;
    }

    setState(() {
      _isConnecting = false;
      _isConnected = false;
    });
    await _openServerSheet(force: true);
  }

  Future<void> _openServerSheet({bool force = false}) async {
    if (_serverSheetOpen) {
      return;
    }

    _serverSheetOpen = true;
    final connectedUrl = await MusicFinderServerSheet.show(
      context,
      client: _musicFinderClient,
      initialUrl: _serverUrl ??
          FinampSettingsHelper.finampSettings.musicFinderServerUrl,
      isDismissible: true,
    );
    _serverSheetOpen = false;

    if (!mounted) {
      return;
    }

    if (connectedUrl != null && connectedUrl.isNotEmpty) {
      setState(() {
        _serverUrl = connectedUrl;
        _isConnected = true;
        _isConnecting = false;
        _searchError = null;
        _result = null;
        _addResult = null;
        _selectedMagnets.clear();
      });
      FinampSettingsHelper.setMusicFinderServerUrl(connectedUrl);
      return;
    }

    setState(() {
      _isConnecting = false;
    });
  }

  /// True when [error] means the Music Finder host is unreachable.
  bool _isUnreachableError(Object error) {
    if (error is TimeoutException ||
        error is SocketException ||
        error is HandshakeException ||
        error is HttpException) {
      return true;
    }
    if (error is MusicFinderException) {
      final code = error.statusCode;
      return code == null || code >= 500;
    }
    return false;
  }

  Future<void> _handleUnreachable(Object error) async {
    if (!_isUnreachableError(error)) {
      return;
    }
    setState(() {
      _isConnected = false;
      _result = null;
      _addResult = null;
      _selectedMagnets.clear();
      _selectedArtistId = null;
    });
    await _openServerSheet(force: true);
  }

  Future<void> _runSearch({String? artistId}) async {
    if (_isSearching || !_isConnected) {
      return;
    }
    if (_songController.text.trim().isEmpty &&
        _artistController.text.trim().isEmpty &&
        _albumController.text.trim().isEmpty) {
      return;
    }

    setState(() {
      _isSearching = true;
      _searchError = null;
      _addResult = null;
      _selectedMagnets.clear();
      if (artistId != null) {
        _selectedArtistId = artistId;
      }
    });

    try {
      final result = await _musicFinderClient.search(
        baseUrl: _baseUrl,
        song: _songController.text.trim(),
        artist: _artistController.text.trim(),
        album: _albumController.text.trim(),
        artistId: artistId ?? _selectedArtistId,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isSearching = false;
        _result = result;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isSearching = false;
        _result = null;
        _searchError = e.toString();
      });
      await _handleUnreachable(e);
    }
  }

  Future<void> _addSelected() async {
    if (!_canAdd) {
      return;
    }

    setState(() {
      _isAdding = true;
      _addResult = null;
    });

    try {
      final addResult = await _musicFinderClient.addMagnets(
        baseUrl: _baseUrl,
        magnets: _selectedMagnets.toList(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isAdding = false;
        _addResult = addResult;
      });
      final messenger = ScaffoldMessenger.of(context);
      final okCount = addResult.results.where((r) => r.ok).length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!
                .musicFinderAddSummary(okCount, addResult.results.length),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isAdding = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
      await _handleUnreachable(e);
    }
  }

  void _onCancel() {
    Navigator.of(context).pop();
  }

  void _toggleSelectAll(bool? select) {
    final candidates = _result?.candidates ?? const [];
    setState(() {
      if (select == true) {
        _selectedMagnets
          ..clear()
          ..addAll(candidates.map((c) => c.magnet));
      } else {
        _selectedMagnets.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final node = FocusScope.of(context);
    final candidates = _result?.candidates ?? const [];
    final allSelected = candidates.isNotEmpty &&
        candidates.every((c) => _selectedMagnets.contains(c.magnet));
    final someSelected = _selectedMagnets.isNotEmpty && !allSelected;

    return Scaffold(
      appBar: AppBar(
        title: Text(localizations.externalSearch),
        actions: [
          if (_isConnected)
            IconButton(
              icon: const Icon(Icons.dns_outlined),
              tooltip: localizations.musicFinderChangeServer,
              onPressed: (_isSearching || _isAdding || _isConnecting)
                  ? null
                  : () => _openServerSheet(force: true),
            ),
        ],
      ),
      bottomNavigationBar: const NowPlayingBar(),
      body: SafeArea(
        child: Column(
          children: [
            if (_isConnecting && _isConnected)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: !_isConnected
                  ? ListView(
                      padding: const EdgeInsets.all(16.0),
                      children: [
                        Text(
                          localizations.musicFinderConnectRequired,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () => _openServerSheet(force: true),
                          icon: const Icon(Icons.dns_outlined),
                          label:
                              Text(localizations.musicFinderOpenServerSetup),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: _onCancel,
                            child: Text(
                              MaterialLocalizations.of(context)
                                  .cancelButtonLabel,
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      padding: const EdgeInsets.all(16.0),
                      children: [
                        TextField(
                          controller: _songController,
                          enabled: !_isSearching && !_isAdding,
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
                          enabled: !_isSearching && !_isAdding,
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
                          enabled: !_isSearching && !_isAdding,
                          textInputAction: TextInputAction.done,
                          onEditingComplete:
                              _canSearch ? () => _runSearch() : null,
                          decoration: InputDecoration(
                            labelText: localizations.album,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: (_isSearching || _isAdding)
                                  ? null
                                  : _onCancel,
                              child: Text(
                                MaterialLocalizations.of(context)
                                    .cancelButtonLabel,
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed:
                                  _canSearch ? () => _runSearch() : null,
                              child: Text(
                                _isSearching
                                    ? localizations.searchingButtonLabel
                                    : localizations.searchButtonLabel,
                              ),
                            ),
                          ],
                        ),
                        if (_searchError != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            _searchError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        if (_result != null) ...[
                          const SizedBox(height: 24),
                          _IdentitySection(
                            result: _result!,
                            selectedArtistId: _selectedArtistId,
                            onArtistSelected: (id) {
                              setState(() => _selectedArtistId = id);
                            },
                            onContinueWithArtist: _isSearching
                                ? null
                                : () {
                                    if (_selectedArtistId != null) {
                                      _runSearch(
                                          artistId: _selectedArtistId);
                                    }
                                  },
                          ),
                        ],
                        if (_result != null && candidates.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(
                            localizations.musicFinderMagnetCandidates,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: DataTable(
                              columns: [
                                DataColumn(
                                  label: Checkbox(
                                    tristate: true,
                                    value: allSelected
                                        ? true
                                        : (someSelected ? null : false),
                                    onChanged:
                                        _isAdding ? null : _toggleSelectAll,
                                  ),
                                ),
                                DataColumn(
                                  label:
                                      Text(localizations.musicFinderScore),
                                ),
                                DataColumn(
                                  label:
                                      Text(localizations.musicFinderTitle),
                                ),
                                DataColumn(
                                  label:
                                      Text(localizations.musicFinderHost),
                                ),
                              ],
                              rows: [
                                for (final c in candidates)
                                  DataRow(
                                    cells: [
                                      DataCell(
                                        Checkbox(
                                          value: _selectedMagnets
                                              .contains(c.magnet),
                                          onChanged: _isAdding
                                              ? null
                                              : (checked) {
                                                  setState(() {
                                                    if (checked == true) {
                                                      _selectedMagnets
                                                          .add(c.magnet);
                                                    } else {
                                                      _selectedMagnets
                                                          .remove(c.magnet);
                                                    }
                                                  });
                                                },
                                        ),
                                      ),
                                      DataCell(
                                        Text(c.score.toStringAsFixed(2)),
                                      ),
                                      DataCell(
                                        SizedBox(
                                          width: 220,
                                          child: Text(
                                            c.title,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                      DataCell(Text(c.host)),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: ElevatedButton(
                              onPressed: _canAdd ? _addSelected : null,
                              child: Text(
                                _isAdding
                                    ? localizations.musicFinderAddingLabel
                                    : localizations.musicFinderAddSelected,
                              ),
                            ),
                          ),
                        ] else if (_result != null &&
                            !_result!.alreadyOwned &&
                            !_result!.needsArtistChoice) ...[
                          const SizedBox(height: 16),
                          Text(localizations.musicFinderNoCandidates),
                          if (_result!.scrapeReports.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            for (final r in _result!.scrapeReports)
                              Text(
                                r.ok
                                    ? "${r.host}: ok (${r.count})"
                                    : "${r.host}: fail ${r.error}",
                                style:
                                    Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ],
                        if (_addResult != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            localizations.musicFinderAddResults,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          for (final r in _addResult!.results)
                            ListTile(
                              dense: true,
                              leading: Icon(
                                r.ok ? Icons.check_circle : Icons.error,
                                color: r.ok
                                    ? Colors.green
                                    : Theme.of(context).colorScheme.error,
                              ),
                              title: Text(
                                r.detail.isEmpty
                                    ? (r.ok ? "ok" : "error")
                                    : r.detail,
                              ),
                              subtitle: Text(
                                r.magnet.length > 72
                                    ? "${r.magnet.substring(0, 72)}…"
                                    : r.magnet,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentitySection extends StatelessWidget {
  const _IdentitySection({
    required this.result,
    required this.selectedArtistId,
    required this.onArtistSelected,
    required this.onContinueWithArtist,
  });

  final MusicFinderSearchResult result;
  final String? selectedArtistId;
  final ValueChanged<String> onArtistSelected;
  final VoidCallback? onContinueWithArtist;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final identity = result.identity;
    final theme = Theme.of(context);

    final showOwned = result.alreadyOwned && identity?.owned != null;
    final showChooser = result.needsArtistChoice &&
        (identity?.artists.isNotEmpty ?? false);
    final showDiagnostics = kDebugMode;

    if (!showOwned && !showChooser && !showDiagnostics) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showDiagnostics)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                title: Text(
                  localizations.musicFinderDiagnostics,
                  style: theme.textTheme.titleMedium,
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      "${localizations.musicFinderIdentity} (${result.status})",
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  if (result.warnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        "${localizations.musicFinderWarnings}: ${result.warnings.join(', ')}",
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                  if (!showChooser && identity?.selected != null) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        localizations.musicFinderSelectedArtist(
                          identity!.selected!.name,
                          identity.selected!.source,
                          (identity.selected!.score * 100).toStringAsFixed(0),
                        ),
                      ),
                    ),
                    if (identity.recordingTitle.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          "${localizations.musicFinderRecordingHint}: ${identity.recordingTitle}",
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ],
              ),
            if (showOwned) ...[
              if (showDiagnostics) const SizedBox(height: 8),
              Text(
                localizations.musicFinderAlreadyOwned(
                  identity!.owned!.artist,
                  identity.owned!.title.isNotEmpty
                      ? identity.owned!.title
                      : identity.owned!.album,
                  identity.owned!.score.toStringAsFixed(2),
                ),
              ),
            ],
            if (showChooser) ...[
              if (showDiagnostics || showOwned) const SizedBox(height: 8),
              Text(localizations.musicFinderChooseArtist),
              for (final a in identity!.artists)
                RadioListTile<String>(
                  dense: true,
                  title: Text(a.name),
                  subtitle: Text(
                    "${a.source} · ${(a.score * 100).toStringAsFixed(0)}%"
                    "${a.disambiguation.isNotEmpty ? ' · ${a.disambiguation}' : ''}",
                  ),
                  value: a.id,
                  groupValue: selectedArtistId,
                  onChanged: onContinueWithArtist == null
                      ? null
                      : (v) {
                          if (v != null) {
                            onArtistSelected(v);
                          }
                        },
                ),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton(
                  onPressed: selectedArtistId == null ||
                          onContinueWithArtist == null
                      ? null
                      : onContinueWithArtist,
                  child: Text(localizations.musicFinderContinueWithArtist),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
