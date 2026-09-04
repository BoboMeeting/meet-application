import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';

/// 统一日志服务：同时输出到控制台和本地日志文件。
///
/// - 日志级别：DEBUG / INFO / WARNING / ERROR
/// - 控制台：彩色 tag（在不支持 ANSI 的环境自动降级为纯文本）
/// - 文件输出：放置于应用可执行文件所在目录的 logs/ 子目录
///   例如 Windows debug 构建：
///     build\windows\x64\runner\Debug\logs\bobomeet_20260904.log
///   按天滚动（新的一天自动新建当日日志文件）。
///
/// 使用：
///   await LoggerService.init();  // main 中调用一次
///   LoggerService.info('message', name: 'MyTag');
///   LoggerService.error('join failed', error: e, stackTrace: st);
class LoggerService {
  LoggerService._();

  static final LoggerService instance = LoggerService._();

  /// 文件写入的 open sink（懒初始化 + 按天滚动）。
  IOSink? _sink;

  /// 当前日志文件日期（用于按天滚动判断）。
  String? _currentDayKey;

  /// 当前日志文件完整路径（init 后可读取，方便用户定位）。
  String? _logFilePath;
  String? get logFilePath => _logFilePath;

  bool _initialized = false;
  bool get initialized => _initialized;

  /// 日志所在目录的绝对路径。
  String? _logDirPath;
  String? get logDirPath => _logDirPath;

  static final DateFormat _fileFmt = DateFormat('yyyyMMdd');
  static final DateFormat _lineFmt = DateFormat('yyyy-MM-dd HH:mm:ss.SSS');

  // ---------------- 初始化 ----------------

  /// 启动日志服务。应在 main() 中 WidgetsFlutterBinding 之后尽早调用。
  ///
  /// [level] 全局最低输出级别，低于该级别的日志会被丢弃。
  /// [logsDirOverride] 若不为空，则强制使用该目录存放日志（主要用于测试）。
  static Future<void> init({
    Level level = Level.ALL,
    String? logsDirOverride,
  }) async {
    if (instance._initialized) return;

    // 确定日志目录
    final dir = await _resolveLogsDirectory(override: logsDirOverride);
    instance._logDirPath = dir;

    Logger.root.level = level;
    Logger.root.onRecord.listen(instance._onRecord);

    // 预创建首日日志文件（确保路径立即可用、目录可写）
    await instance._ensureSink();

    instance._initialized = true;

    // 打印启动标识（便于从日志开头定位一次运行）
    final banner = [
      '==================== BoboMeet 启动 ====================',
      '日志目录: ${instance._logDirPath}',
      '日志文件: ${instance._logFilePath}',
      '平台: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
      'Dart:   ${Platform.version.split('\n').first}',
      '=======================================================',
    ].join('\n');
    Logger.root.info(banner);
  }

  /// 确定日志输出目录。优先使用可执行文件同级 logs/；失败时降级到系统临时目录。
  static Future<String> _resolveLogsDirectory({String? override}) async {
    String candidate;
    if (override != null && override.isNotEmpty) {
      candidate = override;
    } else if (!kIsWeb) {
      // 与可执行文件同目录（Windows 构建用户能方便找到）
      try {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        candidate = '$exeDir${Platform.pathSeparator}logs';
      } catch (_) {
        candidate = '${Directory.systemTemp.path}${Platform.pathSeparator}'
            'bobomeet_logs';
      }
    } else {
      // Web 没有文件系统，给个占位（文件写入分支会被 kIsWeb 短路）
      candidate = './logs';
    }
    final dir = Directory(candidate);
    if (!await dir.exists()) {
      try {
        await dir.create(recursive: true);
      } catch (_) {
        // 权限不足等场景：再退回系统临时目录
        final fallback = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}bobomeet_logs',
        );
        if (!await fallback.exists()) {
          await fallback.create(recursive: true);
        }
        return fallback.path;
      }
    }
    return dir.path;
  }

  // ---------------- 便捷方法（业务层直接调用） ----------------

  static void debug(String message, {String name = ''}) =>
      Logger(name).fine(message);

  static void info(String message, {String name = ''}) =>
      Logger(name).info(message);

  static void warning(String message, {String name = '', Object? error}) =>
      Logger(name).warning(message, error);

  static void error(
    String message, {
    String name = '',
    Object? error,
    StackTrace? stackTrace,
  }) =>
      Logger(name).severe(message, error, stackTrace);

  // ---------------- 内部实现 ----------------

  void _onRecord(LogRecord record) {
    final line = _formatLine(record);
    // 1) 控制台（始终输出，调试时在 IDE 控制台可见）
    // ignore: avoid_print
    print(line);

    // 2) 文件输出（Web 下不写）
    if (kIsWeb || _logDirPath == null) return;
    _writeLineAsync(line, record.time);
  }

  void _writeLineAsync(String line, DateTime time) {
    final dayKey = _fileFmt.format(time);
    // 按天滚动：日期变化时切换到新文件（fire-and-forget：写日志路径本身不能阻塞业务）
    if (dayKey != _currentDayKey) {
      unawaited(_ensureSink(dayKey: dayKey).catchError((Object e, StackTrace st) {
        // ignore: avoid_print
        print('[Logger] 创建日志文件失败: $e\n$st');
      }));
    }
    final sink = _sink;
    if (sink == null) return;
    try {
      sink.writeln(line);
    } catch (e) {
      // ignore: avoid_print
      print('[Logger] 写入日志失败: $e');
    }
  }

  String _formatLine(LogRecord r) {
    final ts = _lineFmt.format(r.time);
    final tag = r.loggerName.isEmpty ? '' : ' [${r.loggerName}]';
    final errorStr =
        r.error == null ? '' : '\n  └─ err: ${r.error?.runtimeType}: ${r.error}';
    final stackStr = r.stackTrace == null
        ? ''
        : '\n${_indentStackTrace(r.stackTrace.toString())}';
    return '$ts [${r.level.name}]$tag ${r.message}$errorStr$stackStr';
  }

  static String _indentStackTrace(String st) =>
      st.split('\n').map((l) => '     $l').join('\n');

  /// 确保当日日志文件 sink 已打开；按天滚动时关闭旧 sink。
  Future<void> _ensureSink({String? dayKey}) async {
    final key = dayKey ?? _fileFmt.format(DateTime.now());
    if (_currentDayKey == key && _sink != null) return;

    // 关闭旧文件
    if (_sink != null) {
      try {
        await _sink!.flush();
        await _sink!.close();
      } catch (_) {}
      _sink = null;
    }

    _currentDayKey = key;
    final path =
        '$_logDirPath${Platform.pathSeparator}bobomeet_$key.log';
    _logFilePath = path;
    if (!kIsWeb) {
      final file = File(path);
      _sink = file.openWrite(mode: FileMode.append);
    }
  }

  /// 应用退出前手动 flush；正常 Dart 进程退出时 OS 也会刷盘，
  /// 提供此方法是为了崩溃前或热重启场景下避免丢最后几行。
  Future<void> flush() async {
    try {
      await _sink?.flush();
    } catch (_) {}
  }
}
