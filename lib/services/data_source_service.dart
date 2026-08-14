import 'dart:async';
import 'dart:core';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import 'finamp_settings_helper.dart';
import 'tailscale_media_proxy.dart';

Logger _dataSourceServiceLogger = Logger("Data Source Service");

enum SourceChangeGenericType { network, transcoding }

enum SourceChangeType { toLocalUrl, toRemoteUrl, toOffline, toOnline, toDirectPlay, toTranscoding }

class DataSourceService {
  static void create() {
    final FinampUserHelper finampUserHelper = GetIt.instance<FinampUserHelper>();
    final ref = GetIt.instance<ProviderContainer>();

    ref.listen(finampSettingsProvider.isOffline, (_, isOffline) {
      if (isOffline) {
        _dataSourceServiceLogger.info("Offline Mode Enabled");
      } else {
        _dataSourceServiceLogger.info("Offline Mode Disabled");
      }
      _onDataSourceChange(isOffline ? SourceChangeType.toOffline : SourceChangeType.toOnline);
    });

    ref.listen(finampSettingsProvider.shouldTranscode, (_, shouldTranscode) {
      if (shouldTranscode) {
        _dataSourceServiceLogger.info("Transcoding Enabled");
      } else {
        _dataSourceServiceLogger.info("Transcoding Disabled");
      }
      _onDataSourceChange(shouldTranscode ? SourceChangeType.toTranscoding : SourceChangeType.toDirectPlay);
    });

    ref.listen(finampSettingsProvider.transcodingStreamingFormat, (_, transcodingStreamingFormat) {
      if (FinampSettingsHelper.finampSettings.shouldTranscode) {
        _dataSourceServiceLogger.info("Transcoding Streaming Format Changed: $transcodingStreamingFormat");
        _onDataSourceChange(SourceChangeType.toTranscoding);
      }
    });

    ref.listen(finampSettingsProvider.transcodeBitrate, (_, transcodeBitrate) {
      if (FinampSettingsHelper.finampSettings.shouldTranscode) {
        _dataSourceServiceLogger.info("Transcoding Bitrate Changed: $transcodeBitrate");
        _onDataSourceChange(SourceChangeType.toTranscoding);
      }
    });

    ref.listen(FinampUserHelper.finampCurrentUserProvider.select((user) => user?.baseURL), (_, newUrl) {
      _dataSourceServiceLogger.info("Base URL Changed: $newUrl");
      _onPlaybackAddressChange(finampUserHelper);
    });

    // Streaming uses publicAddress (and the loopback proxy for tailnet hosts)
    // while Embedded Tailscale is on — see MusicPlayerBackgroundTask._trackUri.
    // baseURL may stay on local/MagicDNS for API, so also rebuild when the
    // Tailscale toggle or public address changes — otherwise the native player
    // keeps stale URLs after startup or network transitions.
    ref.listen(finampSettingsProvider.useEmbeddedTailscale, (_, enabled) {
      _dataSourceServiceLogger.info(
        "Embedded Tailscale ${enabled ? 'enabled' : 'disabled'}; refreshing playback sources",
      );
      if (!enabled) {
        unawaited(TailscaleMediaProxy.instance.stop());
      }
      _onPlaybackAddressChange(finampUserHelper);
    });

    ref.listen(FinampUserHelper.finampCurrentUserProvider.select((user) => user?.publicAddress), (previous, next) {
      if (previous == next) return;
      if (!FinampSettingsHelper.finampSettings.useEmbeddedTailscale) return;
      _dataSourceServiceLogger.info("Public address changed while Embedded Tailscale enabled");
      _onPlaybackAddressChange(finampUserHelper);
    });
  }

  /// Effective streamed-audio address class (not the URL itself).
  static void _onPlaybackAddressChange(FinampUserHelper finampUserHelper) {
    final useEmbeddedTailscale = FinampSettingsHelper.finampSettings.useEmbeddedTailscale;
    final isLocalUrl = !useEmbeddedTailscale && (finampUserHelper.currentUser?.isLocal ?? false);
    _dataSourceServiceLogger.info(
      "Playback address class: ${useEmbeddedTailscale || !isLocalUrl ? 'public' : 'local'}",
    );
    _onDataSourceChange(isLocalUrl ? SourceChangeType.toLocalUrl : SourceChangeType.toRemoteUrl);
  }

  static Future<void> _onDataSourceChange(SourceChangeType event) async {
    if (!GetIt.instance.isRegistered<QueueService>()) return;
    final QueueService queueService = GetIt.instance<QueueService>();
    _dataSourceServiceLogger.finest("Connectivity Change Triggered, event is '$event'");

    final queueInfo = queueService.getQueue();

    if (queueInfo.trackCount > 0) {
      switch (event) {
        case SourceChangeType.toLocalUrl:
        case SourceChangeType.toRemoteUrl:
        case SourceChangeType.toOffline:
          if (queueInfo.undownloadedTracks > 0) {
            if (FinampSettingsHelper.finampSettings.autoReloadQueue) {
              await queueService.reloadQueue();
            } else {
              GlobalSnackbar.message(
                (context) {
                  final reloadPrompt = AppLocalizations.of(
                    context,
                  )!.autoReloadPrompt(SourceChangeGenericType.network.name);
                  final reloadPromptMissingTracks = AppLocalizations.of(
                    context,
                  )!.autoReloadPromptMissingTracks(queueInfo.undownloadedTracks);
                  if (event == SourceChangeType.toOffline && queueInfo.undownloadedTracks > 0) {
                    // we want to warn the user about undownloaded tracks that won't be available after reloading the queue, before they actually reload
                    return "$reloadPrompt. $reloadPromptMissingTracks";
                  } else {
                    return reloadPrompt;
                  }
                },
                action: (context) => SnackBarAction(
                  label: AppLocalizations.of(context)!.autoReloadPromptReloadButton,
                  onPressed: () {
                    // archived queues are not overwritten and can always be restored again
                    bool archivalNeeded = event == SourceChangeType.toOffline;
                    queueService.reloadQueue(archiveQueue: archivalNeeded);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  },
                ),
                isConfirmation: false,
              );
            }
          }
          break;
        case SourceChangeType.toOnline:
          // nop, queue won't change since Finamp prefers downloaded data anyway
          break;
        case SourceChangeType.toDirectPlay:
        case SourceChangeType.toTranscoding:
          final queueInfo = queueService.getQueue();
          final transcodingItemsExist = queueInfo.fullQueue.any((item) => item.item.extras?["shouldTranscode"] == true);
          if (event == SourceChangeType.toTranscoding || transcodingItemsExist) {
            if (FinampSettingsHelper.finampSettings.autoReloadQueue) {
              await queueService.reloadQueue();
            } else {
              GlobalSnackbar.message(
                (context) => AppLocalizations.of(context)!.autoReloadPrompt(SourceChangeGenericType.transcoding.name),
                action: (context) => SnackBarAction(
                  label: AppLocalizations.of(context)!.autoReloadPromptReloadButton,
                  onPressed: () {
                    queueService.reloadQueue(archiveQueue: false);
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  },
                ),
                isConfirmation: false,
              );
            }
          }
          break;
      }
    }
  }
}
