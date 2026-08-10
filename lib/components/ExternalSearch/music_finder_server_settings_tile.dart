import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:hive/hive.dart';

import '../../models/finamp_models.dart';
import '../../services/finamp_settings_helper.dart';
import '../../services/music_finder_client.dart';
import 'music_finder_server_sheet.dart';

/// Settings row to configure Music Finder. External Search UI stays hidden
/// until a URL is saved after a successful health check.
///
/// The stored URL is never shown — only Configured / Not configured.
/// The entry field is always empty (secret is never prefilled).
class MusicFinderServerSettingsTile extends StatelessWidget {
  const MusicFinderServerSettingsTile({Key? key}) : super(key: key);

  Future<void> _configure(BuildContext context) async {
    final client = MusicFinderClient();
    final connectedUrl = await MusicFinderServerSheet.show(
      context,
      client: client,
      isDismissible: true,
    );
    if (!context.mounted) {
      return;
    }
    if (connectedUrl != null && connectedUrl.isNotEmpty) {
      FinampSettingsHelper.setMusicFinderServerUrl(connectedUrl);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppLocalizations.of(context)!.musicFinderServerSaved,
          ),
        ),
      );
    }
  }

  Future<void> _clear(BuildContext context) async {
    FinampSettingsHelper.setMusicFinderServerUrl(null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context)!.musicFinderServerCleared,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;

    return ValueListenableBuilder<Box<FinampSettings>>(
      valueListenable: FinampSettingsHelper.finampSettingsListener,
      builder: (context, box, _) {
        final configured = FinampSettingsHelper.hasMusicFinderServer;
        return ListTile(
          leading: const Icon(Icons.travel_explore_outlined),
          title: Text(localizations.musicFinderServerSheetTitle),
          subtitle: Text(
            configured
                ? localizations.musicFinderServerConfigured
                : localizations.musicFinderServerNotConfigured,
          ),
          onTap: () => _configure(context),
          trailing: configured
              ? IconButton(
                  tooltip: localizations.musicFinderClearServer,
                  icon: const Icon(Icons.clear),
                  onPressed: () => _clear(context),
                )
              : null,
        );
      },
    );
  }
}
