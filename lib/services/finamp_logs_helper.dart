import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:clipboard/clipboard.dart';
import 'package:file_picker/file_picker.dart';
import 'package:finamp/services/censored_log.dart';
import 'package:finamp/services/environment_metadata.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path_helper;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class FinampLogsHelper {
  final List<LogRecord> logs = [];
  IOSink? _logFileWriter;

  /// When this app session started, used as the boundary for [getRecentLogs].
  final DateTime sessionStart = DateTime.now();

  Future<void> openLog() async {
    WidgetsFlutterBinding.ensureInitialized();
    final basePath = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();
    final logFile = File(path_helper.join(basePath.path, "finamp-logs.txt"));
    if (logFile.existsSync() && logFile.lengthSync() >= 1024 * 1024 * 10) {
      logFile.renameSync(path_helper.join(basePath.path, "finamp-logs-old.txt"));
    }
    _logFileWriter = logFile.openWrite(mode: FileMode.writeOnlyAppend);
  }

  void addLog(LogRecord log) {
    logs.add(log);
    if (_logFileWriter != null) {
      // This fails if we log an event before setting up userHelper
      var message = log.censoredMessage;
      if (log.getStack == null) {
        // Truncate long messages from chopper, but leave long stack traces
        message = message.substring(0, min(1024 * 5, message.length));
      }
      _logFileWriter!.writeln(message);
    }

    // We don't want to keep logs forever due to memory constraints.
    if (logs.length > (kDebugMode ? 10000 : 1000)) {
      logs.removeAt(0);
    }
  }

  /// Sanitises all logs and returns a massive string
  String getSanitisedLogs() {
    final logsStringBuffer = StringBuffer();

    for (final log in logs) {
      logsStringBuffer.writeln(log.censoredMessage);
    }

    return logsStringBuffer.toString();
  }

  Future<String> getFullLogs() async {
    final fullLogsBuffer = StringBuffer();

    // Get the Log instance and add its metadata at the top
    final logMeta = await EnvironmentMetadata.create();

    // Prepend this metadata to the logs
    fullLogsBuffer.writeln("=== METADATA ===");
    fullLogsBuffer.writeln(logMeta.pretty);
    fullLogsBuffer.writeln("=== LOGS ===");

    if (_logFileWriter != null) {
      final basePath = (Platform.isAndroid || Platform.isIOS)
          ? await getApplicationDocumentsDirectory()
          : await getApplicationSupportDirectory();
      var oldLogs = File(path_helper.join(basePath.path, "finamp-logs-old.txt"));
      var newLogs = File(path_helper.join(basePath.path, "finamp-logs.txt"));
      if (oldLogs.existsSync()) {
        fullLogsBuffer.write(await oldLogs.readAsString());
      }
      if (newLogs.existsSync()) {
        fullLogsBuffer.write(await newLogs.readAsString());
      }
    } else {
      fullLogsBuffer.write(getSanitisedLogs());
    }
    return fullLogsBuffer.toString();
  }

  /// Logs narrowed to what a bug report needs: this session, plus a short tail
  /// of the previous one.
  ///
  /// [getFullLogs] can span days and reach the 10MB rotation limit, most of it
  /// unrelated to the report. The previous-session tail is included because
  /// crashes and startup failures put the interesting records *before* the
  /// launch the user is reporting from.
  ///
  /// The result is censored the same way [getFullLogs] is: records are written
  /// through [CensoredMessage], and the metadata header omits identifying
  /// details.
  Future<String> getRecentLogs({
    Duration previousSessionWindow = const Duration(minutes: 15),
    int maxBytes = 512 * 1024,
  }) async {
    final buffer = StringBuffer();

    final logMeta = await EnvironmentMetadata.create();
    buffer.writeln("=== METADATA ===");
    buffer.writeln(logMeta.prettyForReport);
    buffer.writeln("=== LOGS ===");

    final String source;
    if (_logFileWriter != null) {
      final basePath = (Platform.isAndroid || Platform.isIOS)
          ? await getApplicationDocumentsDirectory()
          : await getApplicationSupportDirectory();
      final oldLogs = File(path_helper.join(basePath.path, "finamp-logs-old.txt"));
      final newLogs = File(path_helper.join(basePath.path, "finamp-logs.txt"));
      final combined = StringBuffer();
      if (oldLogs.existsSync()) combined.write(await oldLogs.readAsString());
      if (newLogs.existsSync()) combined.write(await newLogs.readAsString());
      source = combined.toString();
    } else {
      source = getSanitisedLogs();
    }

    buffer.write(sliceLogsSince(source, sessionStart.subtract(previousSessionWindow), maxBytes: maxBytes));
    return buffer.toString();
  }

  /// Keeps records timestamped at or after [cutoff], then trims the oldest
  /// until the result fits [maxBytes].
  ///
  /// A record is a line matching the format written by [CensoredMessage]
  /// (`[Logger/LEVEL] timestamp: message`) plus any following indented
  /// continuation lines, so stack traces stay attached to their record. Text
  /// that matches nothing — a truncated or interleaved write, which does
  /// happen — is treated as part of the record above it rather than dropped.
  static String sliceLogsSince(String logText, DateTime cutoff, {int maxBytes = 512 * 1024}) {
    if (logText.isEmpty) return logText;

    final records = <({DateTime? time, String text})>[];
    final buffer = StringBuffer();
    DateTime? currentTime;
    var hasRecord = false;

    void flush() {
      if (hasRecord) records.add((time: currentTime, text: buffer.toString()));
      buffer.clear();
    }

    for (final line in const LineSplitter().convert(logText)) {
      final match = _recordStart.firstMatch(line);
      if (match != null) {
        flush();
        hasRecord = true;
        currentTime = DateTime.tryParse(match.group(1)!);
      }
      if (!hasRecord) {
        // Leading text before the first recognisable record: keep it attached
        // to the start so nothing silently disappears.
        hasRecord = true;
        currentTime = null;
      }
      buffer.writeln(line);
    }
    flush();

    // A record with no parsable timestamp inherits the one before it: it is
    // almost always a continuation, and dropping it would break a stack trace.
    DateTime? inherited;
    final kept = <String>[];
    for (final record in records) {
      inherited = record.time ?? inherited;
      if (inherited == null || !inherited.isBefore(cutoff)) kept.add(record.text);
    }

    var result = kept.join();
    if (result.length <= maxBytes) return result;

    // Trim whole records from the front so the newest survive.
    var dropped = 0;
    while (dropped < kept.length && result.length > maxBytes) {
      result = result.substring(kept[dropped].length);
      dropped++;
    }
    return "[earlier records omitted to keep this report under "
        "${(maxBytes / 1024).round()}KB]\n$result";
  }

  static final RegExp _recordStart = RegExp(r'^\[[^\]\n]+/[A-Z]+\] (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+): ');

  Future<void> copyLogs() async => await FlutterClipboard.copy(getSanitisedLogs());

  /// Write logs to a file and share the file
  Future<void> shareLogs() async {
    final tempDir = await getTemporaryDirectory();
    final (zipName, internalName) = _logExportName();
    final tempFile = File(path_helper.join(tempDir.path, zipName));
    tempFile.createSync();

    await tempFile.writeAsBytes(await _getLogsArchive(internalName));

    final xFile = XFile(tempFile.path, mimeType: "application/zip");
    await SharePlus.instance.share(ShareParams(files: [xFile]));

    await tempFile.delete();
  }

  /// Write logs to a file and save to user-picked directory
  Future<void> exportLogs() async {
    final (zipName, internalName) = _logExportName();

    await FilePicker.saveFile(
      fileName: zipName,
      // initialDirectory is ignored on mobile
      // initialDirectory only seems to work with a trailing separator for some reason
      initialDirectory: (await getApplicationDocumentsDirectory()).path + path_helper.separator,
      bytes: await _getLogsArchive(internalName),
    );
  }

  Future<Uint8List> _getLogsArchive(String name) async {
    final logBytes = utf8.encode(await getFullLogs());
    final archive = Archive();
    archive.add(ArchiveFile.bytes(name, logBytes));
    return ZipEncoder().encodeBytes(archive, level: DeflateLevel.defaultCompression);
  }

  (String, String) _logExportName() {
    final baseName = "finamp-logs-${DateTime.now().toIso8601String().replaceAll(RegExp(r'[/?<>:*|.\\"]'), "-")}";
    return ("$baseName.zip", "$baseName.txt");
  }
}
