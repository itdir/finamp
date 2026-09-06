import 'dart:async';
import 'dart:io';

import 'package:finamp/components/finamp_app_bar_back_button.dart';
import 'package:finamp/l10n/app_localizations.dart';
import 'package:finamp/services/device_display_name.dart';
import 'package:finamp/services/embedded_tailscale_hostname_policy.dart';
import 'package:finamp/services/embedded_tailscale_service.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tailscale/tailscale.dart';
import 'package:url_launcher/url_launcher.dart';

/// Settings for in-process Tailscale (tsnet) used for Jellyfin MagicDNS.
class EmbeddedTailscaleSettingsScreen extends ConsumerStatefulWidget {
  const EmbeddedTailscaleSettingsScreen({super.key});

  static const routeName = '/settings/embedded-tailscale';

  @override
  ConsumerState<EmbeddedTailscaleSettingsScreen> createState() =>
      _EmbeddedTailscaleSettingsScreenState();
}

class _EmbeddedTailscaleSettingsScreenState
    extends ConsumerState<EmbeddedTailscaleSettingsScreen> {
  final _authKeyController = TextEditingController();
  final _hostnameController = TextEditingController();
  StreamSubscription<NodeState>? _stateSub;
  TailscaleStatus? _status;
  String? _error;
  bool _busy = false;
  bool _hostnameReady = false;

  /// Interactive browser login is unsafe on iOS sideloads (empty NSUserActivity
  /// abort). Auth keys only.
  bool get _requireAuthKey => Platform.isIOS || Platform.isAndroid;

  bool get _hostnameLocked =>
      FinampSettingsHelper.finampSettings.embeddedTailscaleHostnameLocked;

  @override
  void initState() {
    super.initState();
    _status = EmbeddedTailscaleService.lastStatus;
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await _prefillHostname();
    final stored = await EmbeddedTailscaleService.loadStoredAuthKey();
    if (stored != null && mounted) {
      _authKeyController.text = stored;
    }
    if (!FinampSettingsHelper.finampSettings.useEmbeddedTailscale) return;
    try {
      await EmbeddedTailscaleService.ensureInitialized();
      _attachStateListener();
      // Bring up if we have no live Running node (covers cold start missed
      // by main(), or status left in starting/needsLogin/stopped).
      if (_status?.isRunning != true) {
        setState(() => _busy = true);
        final status = await EmbeddedTailscaleService.up(
          authKey: stored,
          hostname: _draftHostnameOrNull(),
        );
        if (mounted) {
          setState(() {
            _status = status;
            _busy = false;
            _syncHostnameFromSettings();
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _busy = false;
        });
      }
    }
  }

  Future<void> _prefillHostname() async {
    final settings = FinampSettingsHelper.finampSettings;
    final saved = settings.embeddedTailscaleHostname?.trim();
    if (saved != null && saved.isNotEmpty) {
      _hostnameController.text = saved;
    } else {
      final deviceName = await DeviceDisplayName.read();
      if (!mounted) return;
      _hostnameController.text = slugifyTailscaleHostname(deviceName);
    }
    if (mounted) setState(() => _hostnameReady = true);
  }

  void _syncHostnameFromSettings() {
    final saved =
        FinampSettingsHelper.finampSettings.embeddedTailscaleHostname?.trim();
    if (saved != null && saved.isNotEmpty) {
      _hostnameController.text = saved;
    }
  }

  String? _draftHostnameOrNull() {
    if (_hostnameLocked) return null;
    final raw = _hostnameController.text.trim();
    return raw.isEmpty ? null : raw;
  }

  String? _validateHostname(AppLocalizations l10n) {
    if (_hostnameLocked) return null;
    final raw = _hostnameController.text.trim();
    if (raw.isEmpty) {
      return l10n.embeddedTailscaleHostnameInvalid;
    }
    final slug = isValidTailscaleHostname(raw)
        ? raw
        : slugifyTailscaleHostname(raw);
    if (!isValidTailscaleHostname(slug)) {
      return l10n.embeddedTailscaleHostnameInvalid;
    }
    if (slug != raw) {
      _hostnameController.text = slug;
    }
    return null;
  }

  void _attachStateListener() {
    _stateSub?.cancel();
    _stateSub = EmbeddedTailscaleService.listenState((s) {
      if (mounted) {
        setState(() {
          _status = s;
          if (s.isRunning) _syncHostnameFromSettings();
        });
      }
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _authKeyController.dispose();
    _hostnameController.dispose();
    super.dispose();
  }

  Future<void> _onToggle(bool enabled) async {
    final l10n = AppLocalizations.of(context)!;
    if (enabled) {
      final hostnameError = _validateHostname(l10n);
      if (hostnameError != null) {
        setState(() => _error = hostnameError);
        return;
      }
    }
    FinampSetters.setUseEmbeddedTailscale(enabled);
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      if (enabled) {
        final key = _authKeyController.text.trim();
        if (_requireAuthKey && key.isEmpty) {
          FinampSetters.setUseEmbeddedTailscale(false);
          setState(() {
            _error = l10n.embeddedTailscaleAuthKeyRequired;
          });
          return;
        }
        if (!_hostnameLocked) {
          FinampSetters.setEmbeddedTailscaleHostname(
            resolveEmbeddedTailscaleHostname(
              saved: null,
              locked: false,
              draft: _hostnameController.text,
            ),
          );
        }
        await EmbeddedTailscaleService.ensureInitialized();
        _attachStateListener();
        final status = await EmbeddedTailscaleService.up(
          authKey: key.isEmpty ? null : key,
          hostname: _draftHostnameOrNull(),
        );
        if (mounted) {
          setState(() {
            _status = status;
            _syncHostnameFromSettings();
          });
        }
      } else {
        await EmbeddedTailscaleService.down();
        if (mounted) {
          setState(() => _status = EmbeddedTailscaleService.lastStatus);
        }
      }
    } catch (e) {
      if (enabled) {
        FinampSetters.setUseEmbeddedTailscale(false);
      }
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectWithKey() async {
    final l10n = AppLocalizations.of(context)!;
    final hostnameError = _validateHostname(l10n);
    if (hostnameError != null) {
      setState(() => _error = hostnameError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final key = _authKeyController.text.trim();
      if (_requireAuthKey && key.isEmpty) {
        setState(() {
          _error = l10n.embeddedTailscaleAuthKeyRequired;
        });
        return;
      }
      if (!_hostnameLocked) {
        FinampSetters.setEmbeddedTailscaleHostname(
          resolveEmbeddedTailscaleHostname(
            saved: null,
            locked: false,
            draft: _hostnameController.text,
          ),
        );
      }
      await EmbeddedTailscaleService.ensureInitialized();
      _attachStateListener();
      FinampSetters.setUseEmbeddedTailscale(true);
      // Explicit Connect with a key: enroll if resume is not already Running.
      final status = await EmbeddedTailscaleService.up(
        authKey: key.isEmpty ? null : key,
        hostname: _draftHostnameOrNull(),
        forceEnroll: key.isNotEmpty && EmbeddedTailscaleService.isRunning != true,
      );
      if (mounted) {
        setState(() {
          _status = status;
          _syncHostnameFromSettings();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmReRegister() async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.embeddedTailscaleReRegisterTitle),
        content: Text(l10n.embeddedTailscaleReRegisterConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.embeddedTailscaleReRegisterConfirmButton),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _reRegister();
  }

  Future<void> _reRegister() async {
    setState(() => _busy = true);
    try {
      await EmbeddedTailscaleService.resetRegistration();
      _authKeyController.clear();
      final deviceName = await DeviceDisplayName.read();
      if (!mounted) return;
      setState(() {
        _status = TailscaleStatus.stopped;
        _error = null;
        _hostnameController.text = slugifyTailscaleHostname(deviceName);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusLabel(AppLocalizations l10n) {
    final s = _status;
    if (s == null || s.state == NodeState.stopped || s.state == NodeState.noState) {
      return l10n.embeddedTailscaleStatusDisconnected;
    }
    if (s.isRunning) {
      return l10n.embeddedTailscaleStatusRunning(s.ipv4 ?? '');
    }
    if (s.needsLogin) return l10n.embeddedTailscaleStatusNeedsLogin;
    if (s.state == NodeState.needsMachineAuth) {
      return l10n.embeddedTailscaleStatusNeedsApproval;
    }
    return l10n.embeddedTailscaleStatusOther(s.state.name);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = ref.watch(finampSettingsProvider.useEmbeddedTailscale);
    final locked = ref.watch(finampSettingsProvider.embeddedTailscaleHostnameLocked);
    final hostnameEditable =
        embeddedTailscaleHostnameIsEditable(locked: locked) && !_busy;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.embeddedTailscaleSettingsTitle),
        leading: const FinampAppBarBackButton(),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 200.0),
        children: [
          SwitchListTile.adaptive(
            title: Text(l10n.embeddedTailscaleEnableTitle),
            subtitle: Text(l10n.embeddedTailscaleEnableSubtitle),
            value: enabled,
            onChanged: _busy ? null : _onToggle,
          ),
          ListTile(
            title: Text(l10n.embeddedTailscaleStatusTitle),
            subtitle: Text(
              _busy ? l10n.embeddedTailscaleStatusBusy : _statusLabel(l10n),
            ),
          ),
          if (_error != null)
            ListTile(
              leading: Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(l10n.embeddedTailscaleErrorTitle),
              subtitle: Text(_error!),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _hostnameController,
              enabled: hostnameEditable && _hostnameReady,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                labelText: l10n.embeddedTailscaleHostnameLabel,
                hintText: l10n.embeddedTailscaleHostnameHint,
                helperText: locked
                    ? l10n.embeddedTailscaleHostnameLockedHint
                    : l10n.embeddedTailscaleHostnameHelper,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _authKeyController,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              // Avoid iOS password autofill sheets that create empty
              // NSUserActivity and abort the process.
              autofillHints: const [],
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: _requireAuthKey
                    ? l10n.embeddedTailscaleAuthKeyLabelRequired
                    : l10n.embeddedTailscaleAuthKeyLabel,
                hintText: l10n.embeddedTailscaleAuthKeyHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          ListTile(
            title: Text(l10n.embeddedTailscaleConnectButton),
            subtitle: Text(
              _requireAuthKey
                  ? l10n.embeddedTailscaleConnectSubtitleRequired
                  : l10n.embeddedTailscaleConnectSubtitle,
            ),
            trailing: const Icon(Icons.login),
            enabled: !_busy,
            onTap: _busy ? null : _connectWithKey,
          ),
          if (!_requireAuthKey && (_status?.needsLogin ?? false))
            ListTile(
              title: Text(l10n.embeddedTailscaleOpenLogin),
              subtitle: Text(l10n.embeddedTailscaleOpenLoginSubtitle),
              trailing: const Icon(Icons.open_in_browser),
              onTap: () async {
                final uri = _status?.authUrl;
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                  return;
                }
                await Clipboard.setData(
                  ClipboardData(text: l10n.embeddedTailscaleLoginClipboardHint),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.embeddedTailscaleLoginCopied)),
                  );
                }
              },
            ),
          const Divider(),
          ListTile(
            title: Text(l10n.embeddedTailscaleReRegisterTitle),
            subtitle: Text(l10n.embeddedTailscaleReRegisterSubtitle),
            trailing: const Icon(Icons.refresh),
            enabled: !_busy,
            onTap: _busy ? null : _confirmReRegister,
          ),
        ],
      ),
    );
  }
}
