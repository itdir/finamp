import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tailscale/tailscale.dart';

import 'embedded_tailscale_hostname_policy.dart';
import 'finamp_secrets.dart';
import 'finamp_settings_helper.dart';

/// What [EmbeddedTailscaleService.healAfterNetworkChange] should do.
enum SideloadTsnetHealAction {
  /// Node looks fine; leave it alone.
  none,

  /// Node is not Running — call resume [EmbeddedTailscaleService.ensureRunning].
  resume,

  /// Node reports Running (or is unhealthy) but paths may be stale — `down` + resume `up`.
  restart,
}

/// Pure decision helper for network-change / dial-failure healing.
SideloadTsnetHealAction sideloadTsnetHealAction({
  required bool isRunning,
  required bool isHealthy,
  required bool forceRestart,
}) {
  if (!isRunning) return SideloadTsnetHealAction.resume;
  if (forceRestart || !isHealthy) return SideloadTsnetHealAction.restart;
  return SideloadTsnetHealAction.none;
}

bool sideloadConnectivityLooksUsable(List<ConnectivityResult> results) {
  return results.any(
    (r) =>
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.ethernet ||
        r == ConnectivityResult.vpn ||
        r == ConnectivityResult.other,
  );
}

String sideloadConnectivitySignature(List<ConnectivityResult> results) {
  final names = results.map((r) => r.name).toSet().toList()..sort();
  return names.join(',');
}

/// Wi‑Fi ↔ cellular (or any radio change) must rebuild even if a heal just ran
/// on the dying path and started the cooldown.
bool sideloadTsnetHealShouldIgnoreCooldown({
  required String? previousSignature,
  required String currentSignature,
}) {
  if (previousSignature == null || previousSignature.isEmpty) return false;
  return previousSignature != currentSignature;
}

/// Lifecycle wrapper around [package:tailscale] userspace tsnet.
///
/// Keeps the node state directory under application support. On iOS,
/// AppDelegate excludes application support from iCloud backup (leaked
/// WireGuard keys can impersonate the node).
///
/// **Connect strategy:**
/// 1. Prefer [up] **without** an auth key so persisted credentials reconnect
///    (package:tailscale’s normal cold-start path).
/// 2. Only if that fails or returns [NodeState.needsLogin], enroll with a
///    stored/pasted auth key and `TSNET_FORCE_LOGIN=1` (needed when tsnet
///    would otherwise ignore AuthKey on `NoState`).
///
/// Always passing an auth key + FORCE_LOGIN on every launch breaks auto-connect
/// (one-time keys, and StartLoginInteractive instead of resume).
class EmbeddedTailscaleService {
  EmbeddedTailscaleService._();

  static final _log = Logger('EmbeddedTailscaleService');
  static bool _initialized = false;
  static TailscaleStatus? _lastStatus;
  static Object? _lastError;
  static Future<TailscaleStatus>? _upInFlight;

  static TailscaleStatus? get lastStatus => _lastStatus;
  static Object? get lastError => _lastError;
  static bool get isRunning => _lastStatus?.isRunning ?? false;
  static Uri? get authUrl => _lastStatus?.authUrl;

  static Future<bool>? _ensureRunningInFlight;
  static Future<bool>? _healInFlight;
  static DateTime? _lastHealAt;
  static StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  static AppLifecycleListener? _lifecycleListener;
  static Timer? _connectivitySettleTimer;
  static Timer? _followUpHealTimer;
  static Timer? _nonePollTimer;
  static String? _lastConnectivitySignature;

  /// Minimum gap between forced path rebuilds (network flaps fire many events).
  static const _healCooldown = Duration(seconds: 8);

  /// Wait for Android/iOS interfaces to finish switching before down+up.
  /// Healing immediately often captures an empty/stale netmon snapshot.
  static const _connectivitySettle = Duration(seconds: 2);

  /// Resume tsnet if the node dropped (common after Wi‑Fi ↔ cellular).
  ///
  /// Concurrent callers share one in-flight attempt. Callers on a latency
  /// path (an HTTP request waiting to be sent) should pass `allowEnroll: false`
  /// so a stalled control-plane registration cannot block them; enrollment
  /// belongs to startup and Settings → Embedded Tailscale.
  ///
  /// When [isRunning] is already true this returns immediately. That is the
  /// wrong tool after a radio change: the node can stay `Running` while UDP
  /// paths / Android netmon snapshots are stale — use [healAfterNetworkChange].
  static Future<bool> ensureRunning({Duration timeout = const Duration(seconds: 12), bool allowEnroll = true}) {
    if (isRunning) return Future.value(true);
    return _ensureRunningInFlight ??= _ensureRunningBody(timeout: timeout, allowEnroll: allowEnroll).whenComplete(() {
      _ensureRunningInFlight = null;
    });
  }

  /// Keep tsnet usable across Wi‑Fi ↔ cellular / VPN flaps.
  ///
  /// Independent of Auto Offline: that feature pauses the shared connectivity
  /// listener when disabled, which left MagicDNS-only users stuck until a
  /// process restart. Call once after settings are loaded.
  static void startNetworkWatching() {
    _connectivitySub ??= Connectivity().onConnectivityChanged.listen(_onConnectivityResults);
    _lifecycleListener ??= AppLifecycleListener(
      onResume: () {
        unawaited(
          healAfterNetworkChange(forceRestart: true, ignoreCooldown: true),
        );
      },
    );
  }

  static void _onConnectivityResults(List<ConnectivityResult> results) {
    if (!sideloadConnectivityLooksUsable(results)) {
      _log.info('connectivity → $results (waiting for usable path)');
      _nonePollTimer?.cancel();
      _nonePollTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (timer.tick > 8) {
          timer.cancel();
          return;
        }
        unawaited(_pollConnectivityAfterNone());
      });
      return;
    }
    _nonePollTimer?.cancel();
    _nonePollTimer = null;

    final signature = sideloadConnectivitySignature(results);
    final pathChanged = sideloadTsnetHealShouldIgnoreCooldown(
      previousSignature: _lastConnectivitySignature,
      currentSignature: signature,
    );
    _lastConnectivitySignature = signature;

    _log.info(
      'connectivity → $results signature=$signature pathChanged=$pathChanged; '
      'scheduling tsnet heal in ${_connectivitySettle.inSeconds}s',
    );
    _connectivitySettleTimer?.cancel();
    _followUpHealTimer?.cancel();
    _connectivitySettleTimer = Timer(_connectivitySettle, () {
      unawaited(
        healAfterNetworkChange(
          forceRestart: true,
          ignoreCooldown: pathChanged,
        ),
      );
      if (pathChanged) {
        // iOS often assigns the new address after the first usable event.
        _followUpHealTimer = Timer(const Duration(seconds: 4), () {
          unawaited(
            healAfterNetworkChange(forceRestart: true, ignoreCooldown: true),
          );
        });
      }
    });
  }

  static Future<void> _pollConnectivityAfterNone() async {
    try {
      final now = await Connectivity().checkConnectivity();
      if (sideloadConnectivityLooksUsable(now)) {
        _nonePollTimer?.cancel();
        _nonePollTimer = null;
        _onConnectivityResults(now);
      }
    } catch (e) {
      _log.fine('connectivity poll after none failed: $e');
    }
  }

  /// Stop listening (tests / toggle off). Does not bring the node down.
  static Future<void> stopNetworkWatching() async {
    _connectivitySettleTimer?.cancel();
    _connectivitySettleTimer = null;
    _followUpHealTimer?.cancel();
    _followUpHealTimer = null;
    _nonePollTimer?.cancel();
    _nonePollTimer = null;
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
  }

  /// After the OS network path changes, rebuild tsnet egress if needed.
  ///
  /// `package:tailscale` treats [Tailscale.up] as a no-op while already
  /// Running, and Android's host interface snapshot is only pushed at
  /// start — so a soft [ensureRunning] never recovers a dead path that still
  /// reports Running. Force `down` + resume `up` when [forceRestart] is true
  /// (network-change / failed dial) or health warnings are present.
  ///
  /// Pass [ignoreCooldown]: true for dial/HTTP failures so a premature
  /// connectivity heal cannot block recovery.
  static Future<bool> healAfterNetworkChange({
    bool forceRestart = true,
    bool ignoreCooldown = false,
  }) {
    return _healInFlight ??= _healAfterNetworkChangeBody(
      forceRestart: forceRestart,
      ignoreCooldown: ignoreCooldown,
    ).whenComplete(() {
      _healInFlight = null;
    });
  }

  static Future<bool> _healAfterNetworkChangeBody({
    required bool forceRestart,
    required bool ignoreCooldown,
  }) async {
    try {
      if (!FinampSettingsHelper.finampSettings.useEmbeddedTailscale) {
        return false;
      }
    } catch (_) {
      return false;
    }

    final last = _lastHealAt;
    if (!ignoreCooldown && last != null && DateTime.now().difference(last) < _healCooldown) {
      _log.info(
        'healAfterNetworkChange: within cooldown '
        '(${DateTime.now().difference(last).inMilliseconds}ms ago), skipping',
      );
      return isRunning;
    }

    // Wait for a non-loopback address so start()'s host-network snapshot is
    // not empty (fake iface + cooldown left MagicDNS dead until force-quit).
    if (forceRestart) {
      await _waitForUsableHostInterface();
    }

    try {
      await refreshStatus();
    } catch (e, st) {
      _log.warning('healAfterNetworkChange: status refresh failed', e, st);
    }

    final status = _lastStatus;
    final action = sideloadTsnetHealAction(
      isRunning: status?.isRunning ?? false,
      isHealthy: status?.isHealthy ?? false,
      forceRestart: forceRestart,
    );
    _log.info(
      'healAfterNetworkChange: action=$action '
      'state=${status?.state} healthy=${status?.isHealthy} '
      'health=${status?.health} ignoreCooldown=$ignoreCooldown',
    );

    switch (action) {
      case SideloadTsnetHealAction.none:
        return true;
      case SideloadTsnetHealAction.resume:
        final ok = await ensureRunning(allowEnroll: false);
        if (ok) _lastHealAt = DateTime.now();
        return ok;
      case SideloadTsnetHealAction.restart:
        final ok = await _restartNodeResumeOnly();
        if (ok) _lastHealAt = DateTime.now();
        return ok;
    }
  }

  /// Poll until dart:io sees a usable IPv4/IPv6 or the short budget expires.
  static Future<void> _waitForUsableHostInterface() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final ifaces = await NetworkInterface.list(
          includeLinkLocal: false,
          includeLoopback: false,
          type: InternetAddressType.any,
        );
        final usable = ifaces.any(
          (iface) => iface.addresses.any(
            (a) => !a.isLoopback && !a.isLinkLocal,
          ),
        );
        if (usable) {
          _log.info(
            'Host interfaces ready: '
            '${ifaces.map((i) => '${i.name}=${i.addresses.map((a) => a.address).join(",")}').join('; ')}',
          );
          return;
        }
      } catch (e) {
        _log.fine('Host interface poll failed: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    _log.warning('Host interfaces still empty after wait; proceeding with heal anyway');
  }

  static Future<bool> _restartNodeResumeOnly() async {
    try {
      if (_initialized) {
        await Tailscale.instance.down();
        try {
          _lastStatus = await Tailscale.instance.status();
        } catch (_) {
          _lastStatus = TailscaleStatus.stopped;
        }
      }
    } catch (e, st) {
      _log.warning('heal: down() before restart failed', e, st);
    }
    try {
      final status = await up(resumeOnly: true);
      _log.info(
        'heal restart → state=${status.state} ipv4=${status.ipv4} '
        'healthy=${status.isHealthy} health=${status.health}',
      );
      return status.isRunning;
    } catch (e, st) {
      _log.warning('heal: resume up() after down failed', e, st);
      return false;
    }
  }

  static Future<bool> _ensureRunningBody({required Duration timeout, required bool allowEnroll}) async {
    if (isRunning) return true;
    // [_lastStatus] only advances when up() / refreshStatus() runs, so it can
    // still say "not running" well after the node came up. Ask the runtime
    // before paying for a bring-up.
    try {
      await refreshStatus();
    } catch (_) {}
    if (isRunning) return true;

    final deadline = DateTime.now().add(timeout);
    try {
      // The shared up() future is not cancellable, so bound the wait instead:
      // a slow bring-up must not hold every queued request behind it.
      await up(resumeOnly: !allowEnroll).timeout(timeout);
    } on TimeoutException {
      _log.warning('ensureRunning: up() still pending after ${timeout.inSeconds}s');
    } catch (e, st) {
      _log.warning('ensureRunning up() failed', e, st);
    }
    if (isRunning) return true;
    while (DateTime.now().isBefore(deadline) && !isRunning) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        await refreshStatus();
      } catch (_) {}
    }
    if (!isRunning) {
      _log.warning('ensureRunning: still not Running (state=${lastStatus?.state})');
    }
    return isRunning;
  }

  /// Ensure [Tailscale.init] has been called with a backup-excluded state dir.
  static Future<void> ensureInitialized() async {
    if (_initialized) return;
    await FinampSecrets.ensureInitialized();
    final support = await getApplicationSupportDirectory();
    final stateDir = Directory(p.join(support.path, 'embedded_tailscale'));
    if (!await stateDir.exists()) {
      await stateDir.create(recursive: true);
    }
    Tailscale.init(stateDir: stateDir.path);
    _initialized = true;
    _log.info('Initialized tsnet stateDir=${stateDir.path}');
  }

  static Future<String?> loadStoredAuthKey() => FinampSecrets.loadAuthKey();

  static Future<void> storeAuthKey(String? authKey) => FinampSecrets.storeAuthKey(authKey);

  /// Hostname for tsnet: locked Hive value, else [override], else default.
  static String resolvedHostname({String? override}) {
    try {
      final s = FinampSettingsHelper.finampSettings;
      return resolveEmbeddedTailscaleHostname(
        saved: s.embeddedTailscaleHostname,
        locked: s.embeddedTailscaleHostnameLocked,
        draft: override,
      );
    } catch (_) {
      final o = override?.trim();
      if (o != null && o.isNotEmpty) {
        return isValidTailscaleHostname(o) ? o : slugifyTailscaleHostname(o);
      }
      return kDefaultTailscaleHostname;
    }
  }

  static void _lockHostnameAfterRunning(String hostname, TailscaleStatus status) {
    if (!status.isRunning) return;
    try {
      FinampSetters.setEmbeddedTailscaleHostname(hostname);
      FinampSetters.setEmbeddedTailscaleHostnameLocked(true);
    } catch (e) {
      _log.warning('Could not persist Tailscale hostname lock: $e');
    }
  }

  /// Wipe node credentials and unlock hostname for a fresh setup.
  static Future<void> resetRegistration() async {
    try {
      await logout();
    } catch (e, st) {
      _log.warning('resetRegistration: logout failed', e, st);
    }
    try {
      FinampSetters.setEmbeddedTailscaleHostname(null);
      FinampSetters.setEmbeddedTailscaleHostnameLocked(false);
      FinampSetters.setUseEmbeddedTailscale(false);
    } catch (e) {
      _log.warning('resetRegistration: clear hostname failed: $e');
    }
  }

  /// Bring the node up.
  ///
  /// By default resumes from disk when possible. Pass [forceEnroll] / a fresh
  /// [authKey] to register (or re-register) with the control plane.
  ///
  /// [hostname] is an optional draft when unlocked; locked installs always use
  /// the persisted Hive hostname.
  static Future<TailscaleStatus> up({
    String? authKey,
    String? hostname,
    bool ephemeral = false,
    bool forceEnroll = false,
    bool resumeOnly = false,
  }) {
    final inFlight = _upInFlight;
    if (inFlight != null) {
      _log.fine('Joining in-flight up()');
      return inFlight;
    }

    final resolved = resolvedHostname(override: hostname);

    late final Future<TailscaleStatus> operation;
    operation =
        _upBody(
          authKey: authKey,
          hostname: resolved,
          ephemeral: ephemeral,
          forceEnroll: forceEnroll,
          resumeOnly: resumeOnly,
        ).whenComplete(() {
          if (identical(_upInFlight, operation)) {
            _upInFlight = null;
          }
        });
    _upInFlight = operation;
    return operation;
  }

  static Future<TailscaleStatus> _upBody({
    required String? authKey,
    required String hostname,
    required bool ephemeral,
    required bool forceEnroll,
    bool resumeOnly = false,
  }) async {
    await ensureInitialized();
    _lastError = null;
    _log.info('up() hostname=$hostname forceEnroll=$forceEnroll resumeOnly=$resumeOnly');

    var key = authKey?.trim();
    if (key == null || key.isEmpty) {
      key = await loadStoredAuthKey();
    }

    if (!forceEnroll) {
      final resumed = await _tryResume(hostname: hostname, ephemeral: ephemeral);
      if (resumed != null) {
        if (resumed.isRunning) {
          _lockHostnameAfterRunning(hostname, resumed);
          return resumed;
        }
        if (!resumed.needsLogin) {
          // needsMachineAuth or other stable non-running state
          return resumed;
        }
        if (resumeOnly) {
          _log.info('Resume reached needsLogin; skipping enrollment on a latency-sensitive path');
          return resumed;
        }
        _log.info('Resume reached needsLogin; will enroll with auth key if available');
      }
    }

    if (resumeOnly) {
      _lastStatus ??= TailscaleStatus.stopped;
      return _lastStatus!;
    }

    if (key == null || key.isEmpty) {
      _lastStatus = TailscaleStatus.stopped;
      throw StateError(
        'Embedded Tailscale needs an auth key. Paste a tskey-auth-… key '
        'from the Tailscale admin console, then Connect.',
      );
    }

    final enrolled = await _enrollWithAuthKey(
      key: key,
      hostname: hostname,
      ephemeral: ephemeral,
    );
    _lockHostnameAfterRunning(hostname, enrolled);
    return enrolled;
  }

  /// Resume without auth key (persisted node identity). Returns null if the
  /// native stack rejects the call (typically no state on disk).
  static Future<TailscaleStatus?> _tryResume({required String hostname, required bool ephemeral}) async {
    _clearTsnetForceLogin();
    try {
      final status = await Tailscale.instance.up(hostname: hostname, ephemeral: ephemeral);
      _lastStatus = status;
      _log.info(
        'Resume up() → state=${status.state} ipv4=${status.ipv4} '
        'isRunning=${status.isRunning}',
      );
      return status;
    } catch (e, st) {
      _log.info('Resume without auth key failed (will try enroll if key): $e');
      _log.fine('Resume stack', e, st);
      return null;
    }
  }

  static Future<TailscaleStatus> _enrollWithAuthKey({
    required String key,
    required String hostname,
    required bool ephemeral,
  }) async {
    // Without this, tsnet logs: "Authkey is set; but state is NoState.
    // Ignoring authkey." on first enrollment.
    _enableTsnetForceLogin();
    try {
      final status = await Tailscale.instance.up(hostname: hostname, authKey: key, ephemeral: ephemeral);
      _lastStatus = status;
      await storeAuthKey(key);
      _log.info(
        'Enroll up() → state=${status.state} ipv4=${status.ipv4} '
        'needsLogin=${status.needsLogin} isRunning=${status.isRunning}',
      );
      if (!status.isRunning) {
        _log.warning(
          'tsnet did not reach Running after auth-key enroll '
          '(state=${status.state}). MagicDNS will fail until Running.',
        );
      }
      return status;
    } catch (e, st) {
      _lastError = e;
      _log.severe('enroll up() failed', e, st);
      rethrow;
    } finally {
      // Do not leave FORCE_LOGIN set for the rest of the process lifetime.
      _clearTsnetForceLogin();
    }
  }

  static Future<void> down() async {
    if (!_initialized) return;
    await Tailscale.instance.down();
    _lastStatus = await Tailscale.instance.status();
  }

  /// Revoke the node with the control plane and wipe local state.
  static Future<void> logout() async {
    if (!_initialized) return;
    await Tailscale.instance.logout();
    await storeAuthKey(null);
    _lastStatus = TailscaleStatus.stopped;
  }

  /// Refresh cached status from the native runtime.
  static Future<TailscaleStatus> refreshStatus() async {
    await ensureInitialized();
    _lastStatus = await Tailscale.instance.status();
    return _lastStatus!;
  }

  /// Listen for lifecycle state changes; refreshes [lastStatus] on each event.
  static StreamSubscription<NodeState> listenState(void Function(TailscaleStatus status) onData) {
    return Tailscale.instance.onStateChange.listen((_) async {
      try {
        final status = await Tailscale.instance.status();
        _lastStatus = status;
        onData(status);
      } catch (e, st) {
        _log.warning('status() after state change failed', e, st);
      }
    });
  }

  static void _enableTsnetForceLogin() {
    _setEnv('TSNET_FORCE_LOGIN', '1');
    _log.info('Set TSNET_FORCE_LOGIN=1 for auth-key enrollment');
  }

  static void _clearTsnetForceLogin() {
    _unsetEnv('TSNET_FORCE_LOGIN');
  }

  static void _setEnv(String key, String value) {
    if (kIsWeb) return;
    try {
      final lib = _libc;
      final setenv = lib
          .lookupFunction<
            ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, ffi.Int32),
            int Function(ffi.Pointer<Utf8>, ffi.Pointer<Utf8>, int)
          >('setenv');
      final k = key.toNativeUtf8();
      final v = value.toNativeUtf8();
      try {
        final rc = setenv(k, v, 1);
        if (rc != 0) {
          _log.warning('setenv($key) returned $rc');
        }
      } finally {
        malloc.free(k);
        malloc.free(v);
      }
    } catch (e, st) {
      _log.severe('Failed to setenv($key)', e, st);
    }
  }

  static void _unsetEnv(String key) {
    if (kIsWeb) return;
    try {
      final lib = _libc;
      final unsetenv = lib.lookupFunction<ffi.Int32 Function(ffi.Pointer<Utf8>), int Function(ffi.Pointer<Utf8>)>(
        'unsetenv',
      );
      final k = key.toNativeUtf8();
      try {
        unsetenv(k);
      } finally {
        malloc.free(k);
      }
    } catch (e, st) {
      _log.warning('Failed to unsetenv($key)', e, st);
    }
  }

  static ffi.DynamicLibrary get _libc =>
      (Platform.isAndroid || Platform.isLinux) ? ffi.DynamicLibrary.open('libc.so') : ffi.DynamicLibrary.process();
}
