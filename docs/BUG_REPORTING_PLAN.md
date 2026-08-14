# Plan — basic in-app bug reporting

Status: **steps 1–2 implemented** (log slice, diagnostics summary, metadata
redaction). UI (steps 3–5) not started. Fork-only feature for `itdir/finamp`.

## Why

Diagnosing the iOS playback and Tailscale latency issues took four rounds of:
export a zip → paste a path → grep it. Each round lost information the user
could not know mattered:

- The build number was only recoverable from a Chopper auth header.
- A diagnostic logged at `FINE` never reached the export, because Profile and
  Release builds cap at `INFO` (`lib/setup_logging.dart:52`).
- The first export arrived after the interesting window had already rotated out
  of the on-screen list.

The goal is not a support portal. It is to make one tap produce what a
maintainer actually needs, with the log already narrowed and the environment
already stated.

## What exists today

Export is mature and should be reused rather than reinvented.

| Piece | Location |
|-------|----------|
| Ring buffer + `finamp-logs.txt` (rotates at 10MB) | `lib/services/finamp_logs_helper.dart:18-48` |
| `getFullLogs()` — metadata header + old file + current file | `lib/services/finamp_logs_helper.dart:62-88` |
| Zip build + share sheet | `lib/services/finamp_logs_helper.dart:93-131` |
| Redaction at write time | `lib/services/censored_log.dart:27-95` |
| Environment block (device, app, server) | `lib/services/environment_metadata.dart` |
| Logs screen (`/logs`) | `lib/screens/logs_screen.dart` |

Two gaps matter for a report that may be posted publicly:

1. **Metadata is never censored.** `EnvironmentMetadata.pretty` includes the
   device name and package name verbatim and does not pass through
   `censoredMessage`. Server info is already abstracted to type/port/protocol.
2. **The expanded `LogTile`** renders the raw message and stack
   (`lib/components/LogsScreen/log_tile.dart:72-77`), unlike the export path.
   Out of scope here, but worth knowing the on-screen view is less safe than
   the file.

## Scope

In scope:

- A **Report a problem** screen that collects a short description and attaches
  a narrowed log bundle.
- A **verbose-logging prompt with reproduce-then-report** flow, so the report
  contains `FINE` records instead of an `INFO`-only log.
- A **diagnostics summary** block (build, platform, embedded Tailscale state,
  playback address class) that is short enough to paste into a chat message.

Out of scope: crash capture, telemetry, analytics, any automatic upload.
Reports are always user-initiated and user-visible before they leave the device.

## Design

### Entry points

Add a `ListTile` in `lib/screens/settings_screen.dart` (follow the pattern at
`:142-146`) routing to a new `/settings/report` screen registered in the
`MaterialApp` `routes` map (`lib/main.dart:1041-1084`). Keep the existing Logs
entries in the drawer and login screen unchanged.

Also add a **Report a problem** action to the error snackbar overflow menu, next
to the existing View Logs entry
(`lib/menus/components/menuEntries/view_logs_menu_entry.dart`) — the moment a
user sees an error is the moment they will report it.

### The report screen

Three fields, all optional except the first:

- **What happened** (required, multiline)
- **What you expected**
- **Steps to reproduce**

Below them, a preview card showing exactly what will be attached: the
diagnostics summary in full, and the log slice as a line count plus byte size.
Nothing is attached that the user cannot see first.

A submit button with the standard double-submit guard: disabled while in
flight, busy label, explicit success and failure messages.

### Log slice, not the whole file

The exports handled during the Tailscale work were 1.4MB of text (190KB
zipped) covering multiple days. Almost all of it was irrelevant. Attach instead:

- Every record from the **current app session**, plus
- a **15-minute tail** of the previous session if the app restarted recently
  (crashes and startup failures are exactly the case where the interesting
  records precede the launch), capped at **512KB** uncompressed.

Add `getRecentLogs({Duration window, int maxBytes})` alongside `getFullLogs()`
in `FinampLogsHelper`. A **Attach full history instead** checkbox falls back to
today's `getFullLogs()` for the rare case where more is genuinely needed.

### Diagnostics summary

A new `DiagnosticsSummary` built from `EnvironmentMetadata` plus the state that
proved decisive in recent debugging:

```
Finamp 0.9.25-sideload.7 (133) · iOS 18.7.9 · iPhone11,2
Embedded Tailscale: running (ipv4 present)
Playback address: public, via loopback proxy
Verbose logging: off
Server: Jellyfin 10.11.11 · domain · 8096 · http
```

Every line is a fact that was asked for at least once in the last two debugging
sessions. Note what it does **not** contain: no hostname, no token, no user id,
no device name.

### Redaction

Route the summary and the metadata header through `censoredMessage` before
attaching, and strip the device name and package name from
`EnvironmentMetadata.pretty` when it is bound for a report. The log slice is
already censored at write time, so it needs no further work.

State the redaction plainly on the screen: "Your server address, token, and
device name are removed. Review the preview before sending."

### Destination

The log bundle is a file, and file attachment is what constrains this. GitHub's
issue-prefill URL can carry a title and body but **cannot** attach a file, so
any GitHub-first flow is inherently two steps.

| Option | How | Cost |
|--------|-----|------|
| **A. Share sheet** (recommended) | `SharePlus` with the zip plus the summary as text; user picks Mail, Messages, Files | None — `share_plus` is already used at `finamp_logs_helper.dart:94-105` |
| **B. GitHub issue prefill** | `url_launcher` to `github.com/itdir/finamp/issues/new?title=…&body=…`, then a second tap to share the zip | No Issues URL constant exists yet; only `repoLink` in `settings_screen.dart:95-122` |
| **C. HTTP POST to a self-hosted endpoint** | `http` (already present) to a collector | Needs a service, an auth story, and a retention policy |

Recommend **A** for the "basic" feature, with **B** offered as a secondary
button when the user wants a tracked issue. Defer **C**: it is the only option
that requires infrastructure, and the single-user case does not justify it yet.

### Verbose logging flow

Because Release and Profile cap at `INFO`, a report filed after the fact often
cannot contain the decisive record. On the report screen, when
`verboseLogging` is off, offer:

> Detailed logging is off, so this report may not show the cause.
> **Turn on and reproduce** — then come back and send.

That button calls `FinampSetters.setVerboseLogging(true)` and `applyLogLevel()`
(the same pair used at `lib/components/LogsScreen/verbose_logging_switch.dart:18-20`)
and closes the screen. This is the single highest-value part of the feature: it
converts a useless report into a useful one before it is sent.

## Implementation order

1. `getRecentLogs()` + `DiagnosticsSummary` in the services layer, with unit
   tests for the window/cap logic. No UI.
2. Redaction of the metadata header and summary; test that a known hostname,
   token, and device name do not survive.
3. Report screen + route + Settings tile, share-sheet submission.
4. Snackbar overflow entry and the verbose-logging prompt.
5. GitHub prefill as a secondary action, adding an `issuesLink` constant beside
   the existing repo links.

Steps 1–2 are independently useful: they improve what every existing export
contains, even if the UI never ships.

## Localization

New keys in `lib/l10n/app_en.arb`, then codegen. Existing neighbours to match
in tone: `verboseLoggingSubtitle`, `shareLogs`, `exportLogs`,
`startupErrorCallToAction`. Note `startupErrorCallToAction` still points at
`github.com/jmshrv/finamp` (upstream) — a fork-only report flow should point at
`itdir/finamp`, and that string should be updated in the same change.

## Settings storage

Only if a preference is actually needed (for example, remembering the "attach
full history" choice): next free `FinampSettings` Hive field is **161**
(`lib/models/finamp_models.dart`, highest in use is 160). Prefer adding no
persisted state in the first cut.

## Risks

- **Over-collection.** The temptation is to attach everything. The 512KB cap
  and the visible preview are what keep this honest.
- **Redaction regressions.** `censoredMessage` depends on `FinampUserHelper`
  being registered (`censored_log.dart:36`); during early startup it is not, so
  records from that window are uncensored. A report that includes a previous
  session's startup can therefore leak. Tests must cover the not-registered
  path.
- **Upstream divergence.** This is fork-only. Keep it in files that do not
  conflict heavily with upstream, and do not modify `LogTile` or the existing
  export buttons beyond what step 2 requires.
