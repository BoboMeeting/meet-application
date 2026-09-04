import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../models/room_models.dart';
import 'auth_service.dart';

/// 房间接口服务：对接管理平台 RoomEndpoints。
///
/// - GET    {baseUrl}/api/rooms/                → 列出我的房间
/// - GET    {baseUrl}/api/rooms/{id}            → 查询房间详情
/// - POST   {baseUrl}/api/rooms/create          → 预约会议
/// - GET    {baseUrl}/api/rooms/{roomId}/join    → 获取入会 token（入会）
class RoomService {
  RoomService._();
  static final RoomService instance = RoomService._();

  http.Client? _client;
  http.Client get _httpClient => _client ??= http.Client();

  /// 测试专用：注入 MockClient。
  @visibleForTesting
  set debugHttpClient(http.Client client) => _client = client;

  Map<String, String> get _authHeaders {
    final token = AuthService.instance.accessToken;
    return {
      'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty)
        'Authorization': 'Bearer $token',
    };
  }

  String _urlOf(String path) {
    final base = AuthService.instance.baseUrl;
    if (base == null) {
      throw RoomApiException('未登录，请先登录管理平台');
    }
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
    final resp = await _httpClient
        .get(Uri.parse(_urlOf('/api/rooms/')), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final msg = _tryError(resp) ?? '请求失败（HTTP ${resp.statusCode}）';
      throw RoomApiException(msg);
    }
    if (resp.body.trim().isEmpty) return [];
    final decoded = jsonDecode(resp.body);
    final List raw;
    if (decoded is List) {
      raw = decoded;
    } else if (decoded is Map<String, dynamic>) {
      // 兼容可能的 $values / items 包裹（minimal API 通常直接返回数组）
      final v = decoded['\$values'] ?? decoded['items'];
      raw = v is List ? v : const [];
    } else {
      raw = const [];
    }
    return raw
        .whereType<Map<String, dynamic>>()
        .map(RoomSummary.fromJson)
        .toList();
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
    final resp = await _httpClient
        .get(Uri.parse(_urlOf('/api/rooms/$roomId')), headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    final body = _decode(resp);
    if (body == null) throw RoomApiException('房间信息为空');
    return RoomSummary.fromJson(body);
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
    final payload = <String, dynamic>{
      'title': title,
      if (startTime != null)
        'startTime': startTime.toUtc().toIso8601String(),
      if (durationSeconds != null) 'durationSeconds': durationSeconds,
      if (maxParticipants != null) 'maxParticipants': maxParticipants,
      if (inviteCode != null && inviteCode.isNotEmpty)
        'inviteCode': inviteCode,
    };
    final resp = await _httpClient
        .post(Uri.parse(_urlOf('/api/rooms/create')),
            headers: _authHeaders, body: jsonEncode(payload))
        .timeout(const Duration(seconds: 15));
    final body = _decode(resp);
    if (body == null) throw RoomApiException('创建房间响应为空');
    return RoomSummary.fromJson(body);
  }

  /// 获取入会 token。对应后端 GET /api/rooms/{roomId}/join?nickname=xxx。
  ///
  /// 后端会获取/创建当前进行中的会议场次，返回 LiveKit token 与 URL。
  Future<JoinRoomResult> joinRoom(String roomId, {String? nickname}) async {
    final uri = Uri.parse(_urlOf('/api/rooms/$roomId/join')).replace(
      queryParameters:
          (nickname != null && nickname.isNotEmpty) ? {'nickname': nickname} : null,
    );
    final resp = await _httpClient
        .get(uri, headers: _authHeaders)
        .timeout(const Duration(seconds: 15));
    final body = _decode(resp);
    if (body == null) throw RoomApiException('入会响应为空');
    return JoinRoomResult.fromJson(body);
  }
}
