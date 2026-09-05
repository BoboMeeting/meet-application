import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../models/room_models.dart';
import 'auth_service.dart';
import 'logger_service.dart' as log;

/// 房间接口服务：对接管理平台 RoomEndpoints + 调度服务 MeetingEndpoints。
///
/// 入会流程（两步骤，参照加入会议流程.md）：
///   1) 调管理平台：GET /api/rooms/{roomId}/join?nickname=xxx
///                 → 返回 { schedulerUrl, roomTicket, ... }（调度地址 + 房间凭证）
///   2) 调调度服务：POST {schedulerUrl}/api/v1/external/rooms/join
///                 Header: Authorization: Bearer {用户登录JWT}
///                 Body:   { "ticket": roomTicket }
///                 → 返回 { liveKitUrl, liveKitToken, ... }（LiveKit 连接参数）
///
/// 其余接口（列表、查询、预约等）只走管理平台：
///   - GET    {baseUrl}/api/rooms/                → 列出我的房间
///   - GET    {baseUrl}/api/rooms/{id}            → 查询房间详情
///   - POST   {baseUrl}/api/rooms/create          → 预约会议
///   - POST   {baseUrl}/api/rooms/{id}/cancel     → 取消会议（仅主持人）
class RoomService {
  RoomService._();
  static final RoomService instance = RoomService._();

  static const _tag = 'RoomService';

  http.Client? _client;
  http.Client get _httpClient => _client ??= http.Client();

  /// 测试专用：注入 MockClient。
  @visibleForTesting
  set debugHttpClient(http.Client client) => _client = client;

  /// 统一请求头（携带用户登录 JWT）；同时用于管理平台和调度服务的鉴权。
  Map<String, String> get _authHeaders {
    final token = AuthService.instance.accessToken;
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token',
    };
  }

  /// 对拼接管理平台的 path 构造完整 URL。
  String _urlOf(String path) {
    final base = AuthService.instance.baseUrl;
    if (base == null) {
      throw RoomApiException('未登录，请先登录管理平台');
    }
    return '$base$path';
  }

  /// 对调度服务的 path 基于其 baseUrl 构造完整 URL，并规范化双斜杠。
  static String _schedulerUrlOf(String schedulerBase, String path) {
    final base = schedulerBase.endsWith('/')
        ? schedulerBase.substring(0, schedulerBase.length - 1)
        : schedulerBase;
    return '$base$path';
  }

  /// 解析响应体并校验状态码，失败抛 [RoomApiException]。
  Map<String, dynamic>? _decode(http.Response resp) {
    Map<String, dynamic>? body;
    if (resp.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {
        // 非 JSON，按状态码处理
      }
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final msg = body?['error'] as String? ?? '请求失败（HTTP ${resp.statusCode}）';
      throw RoomApiException(msg);
    }
    return body;
  }

  /// 列出当前登录用户的房间。
  Future<List<RoomSummary>> listMyRooms() async {
    final sw = Stopwatch()..start();
    final url = _urlOf('/api/rooms/');
    log.LoggerService.info('GET /api/rooms/  base=${AuthService.instance.baseUrl}', name: _tag);
    try {
      final resp = await _httpClient
          .get(Uri.parse(url), headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      sw.stop();
      log.LoggerService.info(
        'GET /api/rooms/  HTTP ${resp.statusCode}  elapsed=${sw.elapsedMilliseconds}ms  bodyLen=${resp.body.length}',
        name: _tag,
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        final msg = _tryError(resp) ?? '请求失败（HTTP ${resp.statusCode}）';
        log.LoggerService.warning('GET /api/rooms/  error: $msg', name: _tag);
        throw RoomApiException(msg);
      }
      if (resp.body.trim().isEmpty) return [];
      final decoded = jsonDecode(resp.body);
      final List raw;
      if (decoded is List) {
        raw = decoded;
      } else if (decoded is Map<String, dynamic>) {
        final v = decoded['\$values'] ?? decoded['items'];
        raw = v is List ? v : const [];
      } else {
        raw = const [];
      }
      log.LoggerService.debug('GET /api/rooms/  房间数=${raw.length}', name: _tag);
      return raw
          .whereType<Map<String, dynamic>>()
          .map(RoomSummary.fromJson)
          .toList();
    } on RoomApiException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      log.LoggerService.error(
        'GET /api/rooms/  失败 elapsed=${sw.elapsedMilliseconds}ms  err=$e',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  String? _tryError(http.Response resp) {
    if (resp.body.isEmpty) return null;
    try {
      final d = jsonDecode(resp.body);
      if (d is Map<String, dynamic>) return d['error'] as String?;
    } catch (_) {}
    return null;
  }

  /// 查询房间详情。
  Future<RoomSummary> getRoom(String roomId) async {
    final sw = Stopwatch()..start();
    final url = _urlOf('/api/rooms/$roomId');
    log.LoggerService.info('GET /api/rooms/$roomId', name: _tag);
    try {
      final resp = await _httpClient
          .get(Uri.parse(url), headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      sw.stop();
      log.LoggerService.info(
        'GET /api/rooms/$roomId  HTTP ${resp.statusCode}  elapsed=${sw.elapsedMilliseconds}ms',
        name: _tag,
      );
      final body = _decode(resp);
      if (body == null) throw RoomApiException('房间信息为空');
      return RoomSummary.fromJson(body);
    } on RoomApiException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      log.LoggerService.error(
        'GET /api/rooms/$roomId  失败 elapsed=${sw.elapsedMilliseconds}ms',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// 预约会议。成功后返回新建房间摘要。
  ///
  /// [startTime] 为 null 表示立即开始；[durationSeconds] 为 null 表示默认 1 小时。
  Future<RoomSummary> createRoom({
    required String title,
    DateTime? startTime,
    int? durationSeconds,
    int? maxParticipants,
    String? inviteCode,
  }) async {
    final sw = Stopwatch()..start();
    final payload = <String, dynamic>{
      'title': title,
      if (startTime != null)
        'startTime': startTime.toUtc().toIso8601String(),
      if (durationSeconds != null) 'durationSeconds': durationSeconds,
      if (maxParticipants != null) 'maxParticipants': maxParticipants,
      if (inviteCode != null && inviteCode.isNotEmpty)
        'inviteCode': inviteCode,
    };
    log.LoggerService.info(
      'POST /api/rooms/create  title=$title  duration=${durationSeconds ?? 3600}s  max=${maxParticipants ?? 50}',
      name: _tag,
    );
    try {
      final resp = await _httpClient
          .post(Uri.parse(_urlOf('/api/rooms/create')),
              headers: _authHeaders, body: jsonEncode(payload))
          .timeout(const Duration(seconds: 15));
      sw.stop();
      log.LoggerService.info(
        'POST /api/rooms/create  HTTP ${resp.statusCode}  elapsed=${sw.elapsedMilliseconds}ms',
        name: _tag,
      );
      final body = _decode(resp);
      if (body == null) throw RoomApiException('创建房间响应为空');
      final room = RoomSummary.fromJson(body);
      log.LoggerService.info(
        '创建房间成功  roomId=${room.id}  roomName=${room.roomName}',
        name: _tag,
      );
      return room;
    } on RoomApiException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      log.LoggerService.error(
        'POST /api/rooms/create  失败 elapsed=${sw.elapsedMilliseconds}ms',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// 取消会议（仅主持人/管理员）。成功后返回更新后的房间摘要（状态为已取消）。
  ///
  /// 对应后端：POST /api/rooms/{roomId}/cancel
  Future<RoomSummary> cancelRoom(String roomId) async {
    final sw = Stopwatch()..start();
    log.LoggerService.info('POST /api/rooms/$roomId/cancel', name: _tag);
    try {
      final resp = await _httpClient
          .post(Uri.parse(_urlOf('/api/rooms/$roomId/cancel')),
              headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      sw.stop();
      log.LoggerService.info(
        'POST /api/rooms/$roomId/cancel  HTTP ${resp.statusCode}  elapsed=${sw.elapsedMilliseconds}ms',
        name: _tag,
      );
      final body = _decode(resp);
      if (body == null) throw RoomApiException('取消会议响应为空');
      final room = RoomSummary.fromJson(body);
      log.LoggerService.info(
        '取消会议成功  roomId=${room.id}  status=${room.statusStr}',
        name: _tag,
      );
      return room;
    } on RoomApiException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      log.LoggerService.error(
        'POST /api/rooms/$roomId/cancel  失败 elapsed=${sw.elapsedMilliseconds}ms',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// 入会第一步：调管理平台获取调度地址 + 房间凭证（RoomTicket）。
  ///
  /// 对应后端：GET /api/rooms/{roomId}/join?nickname=xxx
  /// 响应：JoinRoomResponse { schedulerUrl, roomTicket, roomId, conferenceId, ... }
  Future<JoinRoomResult> joinRoom(String roomId, {String? nickname}) async {
    final sw = Stopwatch()..start();
    final base = AuthService.instance.baseUrl ?? '<未设置>';
    final uri = Uri.parse(_urlOf('/api/rooms/$roomId/join')).replace(
      queryParameters:
          (nickname != null && nickname.isNotEmpty) ? {'nickname': nickname} : null,
    );
    log.LoggerService.info(
      '[入会Step1] GET /api/rooms/$roomId/join?nickname=${nickname ?? ''}  baseUrl=$base  fullUrl=${uri.toString()}',
      name: _tag,
    );
    try {
      final resp = await _httpClient
          .get(uri, headers: _authHeaders)
          .timeout(const Duration(seconds: 15));
      sw.stop();
      log.LoggerService.info(
        '[入会Step1] HTTP ${resp.statusCode}  elapsed=${sw.elapsedMilliseconds}ms  bodyLen=${resp.body.length}',
        name: _tag,
      );
      final body = _decode(resp);
      if (body == null) throw RoomApiException('入会响应为空');
      final result = JoinRoomResult.fromJson(body);
      log.LoggerService.info(
        '[入会Step1] 成功  conferenceId=${result.conferenceId}  schedulerUrl=${result.schedulerUrl}  roomTicket(前20)=${result.roomTicket.length >= 20 ? result.roomTicket.substring(0, 20) : result.roomTicket}...',
        name: _tag,
      );
      return result;
    } on RoomApiException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      // 特别标记超时：用户最关心的场景（服务没部署时一定会出现）
      final isTimeout =
          e.toString().toLowerCase().contains('timeout') ||
          e is TimeoutException ||
          (sw.elapsedMilliseconds >= 15000 - 200); // 接近 15s 阈值
      final type = isTimeout ? '超时' : '失败';
      log.LoggerService.error(
        '[入会Step1] $type elapsed=${sw.elapsedMilliseconds}ms  url=$uri  err=${e.runtimeType}: $e',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      if (isTimeout && e is! RoomApiException) {
        throw RoomApiException(
          '管理平台请求超时（${sw.elapsedMilliseconds}ms），请确认管理平台地址 $base 是否可访问且已部署 /api/rooms/$roomId/join 接口',
        );
      }
      rethrow;
    }
  }

  /// 入会第二步：用【用户登录 JWT + RoomTicket】调调度服务外部接口
  /// 换取 LiveKit 连接参数（liveKitUrl + liveKitToken）。
  ///
  /// 对应后端：POST {schedulerUrl}/api/v1/external/rooms/join
  /// Header: Authorization: Bearer {userAccessToken}
  /// Body:   { "ticket": roomTicket }
  Future<SchedulerJoinResult> exchangeSchedulerJoin({
    required String schedulerUrl,
    required String roomTicket,
  }) async {
    final sw = Stopwatch()..start();
    if (schedulerUrl.trim().isEmpty) {
      throw RoomApiException('调度服务地址为空');
    }
    if (roomTicket.trim().isEmpty) {
      throw RoomApiException('房间凭证为空');
    }
    final token = AuthService.instance.accessToken;
    if (token == null || token.isEmpty) {
      throw RoomApiException('未登录，请先登录管理平台');
    }

    final url = _schedulerUrlOf(schedulerUrl, '/api/v1/external/rooms/join');
    log.LoggerService.info(
      '[入会Step2] POST $url  ticketLen=${roomTicket.length}',
      name: _tag,
    );
    try {
      final resp = await _httpClient
          .post(
            Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'ticket': roomTicket}),
          )
          .timeout(const Duration(seconds: 15));
      sw.stop();
      log.LoggerService.info(
        '[入会Step2] HTTP ${resp.statusCode}  elapsed=${sw.elapsedMilliseconds}ms  bodyLen=${resp.body.length}',
        name: _tag,
      );
      final body = _decode(resp);
      if (body == null) throw RoomApiException('调度服务响应为空');
      final result = SchedulerJoinResult.fromJson(body);
      log.LoggerService.info(
        '[入会Step2] 成功  isHost=${result.isHost}  liveKitUrl=${result.liveKitUrl}  token(前16)=${result.liveKitToken.length >= 16 ? result.liveKitToken.substring(0, 16) : result.liveKitToken}...',
        name: _tag,
      );
      return result;
    } on RoomApiException {
      rethrow;
    } catch (e, st) {
      sw.stop();
      final isTimeout =
          e.toString().toLowerCase().contains('timeout') ||
          e is TimeoutException ||
          sw.elapsedMilliseconds >= 15000 - 200;
      final type = isTimeout ? '超时' : '失败';
      log.LoggerService.error(
        '[入会Step2] $type elapsed=${sw.elapsedMilliseconds}ms  schedulerUrl=$schedulerUrl  err=${e.runtimeType}: $e',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      if (isTimeout && e is! RoomApiException) {
        throw RoomApiException(
          '调度服务请求超时（${sw.elapsedMilliseconds}ms），请确认调度服务地址 $schedulerUrl 是否可访问且已部署',
        );
      }
      rethrow;
    }
  }
}
