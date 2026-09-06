/// Pure helpers for Embedded Tailscale machine hostnames.
///
/// Chosen once at setup (user may edit a slug of the OS device name), then
/// locked until Re-register. No random suffix — uniqueness is the user's label.

const String kDefaultTailscaleHostname = 'finamp';

/// Max DNS label length Tailscale/DNS accept for a single hostname segment.
const int kTailscaleHostnameMaxLength = 63;

/// Lowercase DNS-safe slug for [raw] (device name or user edit).
///
/// Strips apostrophes, maps runs of non `[a-z0-9]` to `-`, collapses dashes,
/// trims edges, caps length. Empty input → [kDefaultTailscaleHostname].
String slugifyTailscaleHostname(String raw) {
  var s = raw.trim().toLowerCase();
  if (s.isEmpty) return kDefaultTailscaleHostname;

  // "BP's iPhone" → "bps iphone" then dashes.
  s = s.replaceAll("'", '').replaceAll('’', '');
  final buf = StringBuffer();
  var lastDash = false;
  for (final code in s.runes) {
    final isDigit = code >= 0x30 && code <= 0x39;
    final isLower = code >= 0x61 && code <= 0x7a;
    if (isDigit || isLower) {
      buf.writeCharCode(code);
      lastDash = false;
    } else if (!lastDash) {
      buf.write('-');
      lastDash = true;
    }
  }
  s = buf.toString();
  while (s.startsWith('-')) {
    s = s.substring(1);
  }
  while (s.endsWith('-')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return kDefaultTailscaleHostname;
  if (s.length > kTailscaleHostnameMaxLength) {
    s = s.substring(0, kTailscaleHostnameMaxLength);
    while (s.endsWith('-')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.isEmpty) return kDefaultTailscaleHostname;
  }
  return s;
}

/// True when [hostname] is already a valid Tailscale machine name label.
bool isValidTailscaleHostname(String hostname) {
  if (hostname.isEmpty || hostname.length > kTailscaleHostnameMaxLength) {
    return false;
  }
  if (hostname.startsWith('-') || hostname.endsWith('-')) return false;
  return RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(hostname);
}

/// Whether the hostname field should be editable in Settings.
bool embeddedTailscaleHostnameIsEditable({required bool locked}) => !locked;

/// Hostname to pass to tsnet: saved locked name, else [draft], else default.
String resolveEmbeddedTailscaleHostname({
  required String? saved,
  required bool locked,
  String? draft,
}) {
  if (locked) {
    final s = saved?.trim() ?? '';
    if (s.isNotEmpty && isValidTailscaleHostname(s)) return s;
    return slugifyTailscaleHostname(s.isEmpty ? kDefaultTailscaleHostname : s);
  }
  final d = draft?.trim();
  if (d != null && d.isNotEmpty) {
    final slug = isValidTailscaleHostname(d) ? d : slugifyTailscaleHostname(d);
    return slug;
  }
  final s = saved?.trim();
  if (s != null && s.isNotEmpty) {
    return isValidTailscaleHostname(s) ? s : slugifyTailscaleHostname(s);
  }
  return kDefaultTailscaleHostname;
}
