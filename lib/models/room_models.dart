import 'package:flutter/foundation.dart' show visibleForTesting;

/// 房间状态枚举（对应后端 MeetingRoomStatus：Scheduled=0/Open=1/Closed=2/Cancelled=3）
enum RoomStatus {
  scheduled(0),
  open(1),
  closed(2),
  cancelled(3);

  const RoomStatus(this.value);
  final int value;

  static RoomStatus fromInt(int v) =>
      RoomStatus.values.firstWhere((e) => e.value == v,
          orElse: () => RoomStatus.scheduled);
}

/// 对应后端 RoomSummary（Dtos.cs）。
/// 后端枚举 status 以数字序列化；statusStr 为服务端计算好的中文显示文案。
class RoomSummary {
  const RoomSummary({
    required this.id,
    required this.title,
    required this.roomName,
    required this.hostUserId,
    required this.hostNickname,
    required this.startTime,
    required this.endTime,
    required this.maxParticipants,
    required this.status,
    required this.statusStr,
    required this.locked,
    required this.inviteCode,
    required this.createdAt,
  });

  factory RoomSummary.fromJson(Map<String, dynamic> json) => RoomSummary(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        roomName: json['roomName'] as String? ?? '',
        hostUserId: json['hostUserId'] as String? ?? '',
        hostNickname: json['hostNickname'] as String? ?? '',
        startTime:
            DateTime.tryParse(json['startTime'] as String? ?? '') ??
                DateTime.now(),
        endTime:
            DateTime.tryParse(json['endTime'] as String? ?? '') ??
                DateTime.now(),
        maxParticipants: (json['maxParticipants'] as num?)?.toInt() ?? 0,
        status: RoomStatus.fromInt((json['status'] as num?)?.toInt() ?? 0),
        statusStr: json['statusStr'] as String? ?? '',
        locked: json['locked'] as bool? ?? false,
        inviteCode: json['inviteCode'] as String?,
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );

  final String id;
  final String title;
  final String roomName;
  final String hostUserId;
  final String hostNickname;
  final DateTime startTime;
  final DateTime endTime;
  final int maxParticipants;
  final RoomStatus status;
  final String statusStr;
  final bool locked;
  final String? inviteCode;
  final DateTime createdAt;

  /// 当前用户是否为该会议主持人。
  bool isHostBy(String userId) => hostUserId == userId;

  /// 距开始是否不足 15 分钟（用于"即将开始"黄色徽章）。
  bool isStartingSoon(DateTime now) =>
      (status == RoomStatus.scheduled || status == RoomStatus.open) &&
      startTime.difference(now).inMinutes < 15 &&
      startTime.isAfter(now);

  /// 是否为进行中。
  bool get isInProgress => statusStr == '进行中';

  /// 是否属于历史会议（已结束或已取消）。
  bool get isHistory =>
      status == RoomStatus.closed || status == RoomStatus.cancelled;
}

/// 对应后端 JoinRoomResponse（Dtos.cs）—— 管理平台入会第一步响应。
/// v3.0：管理平台不再签发 LiveKit Token，而是返回调度服务（外部）地址 + 房间凭证。
/// 客户端需再用【用户登录 JWT + RoomTicket】调用调度服务外部接口换取 LiveKit 连接参数。
class JoinRoomResult {
  const JoinRoomResult({
    required this.roomId,
    required this.conferenceId,
    required this.roomName,
    required this.schedulerUrl,
    required this.roomTicket,
    required this.isHost,
    this.user,
  });

  factory JoinRoomResult.fromJson(Map<String, dynamic> json) => JoinRoomResult(
        roomId: json['roomId'] as String? ?? '',
        conferenceId: json['conferenceId'] as String? ?? '',
        roomName: json['roomName'] as String? ?? '',
        schedulerUrl: json['schedulerUrl'] as String? ?? '',
        roomTicket: json['roomTicket'] as String? ?? '',
        isHost: json['isHost'] as bool? ?? false,
        user: () {
          final u = json['user'];
          if (u is Map<String, dynamic>) {
            return JoinUserInfo.fromJson(u);
          }
          return null;
        }(),
      );

  final String roomId;
  final String conferenceId;
  final String roomName;

  /// 调度服务外部接口基地址（EffectiveExternalBaseUrl）。
  final String schedulerUrl;

  /// 短期房间凭证 JWT，需配合用户登录 JWT 调用调度服务换取 LiveKit Token。
  final String roomTicket;

  final bool isHost;

  /// 入会用户详情（可选，服务端一并返回）。
  final JoinUserInfo? user;
}

/// 管理平台 JoinRoomResponse 中附带的用户信息快照（对应后端 UserInfo）。
class JoinUserInfo {
  const JoinUserInfo({
    required this.id,
    required this.account,
    required this.nickname,
    this.avatarUrl,
    required this.role,
    required this.status,
  });

  factory JoinUserInfo.fromJson(Map<String, dynamic> json) => JoinUserInfo(
        id: json['id'] as String? ?? '',
        account: json['account'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        avatarUrl: json['avatarUrl'] as String?,
        role: '${json['role'] ?? ''}',
        status: '${json['status'] ?? ''}',
      );

  final String id;
  final String account;
  final String nickname;
  final String? avatarUrl;
  final String role;
  final String status;
}

/// 调度服务入会第二步响应：POST /api/v1/external/rooms/join。
/// 携带用户 JWT + RoomTicket 调用后返回 LiveKit 连接参数。
class SchedulerJoinResult {
  const SchedulerJoinResult({
    required this.roomName,
    required this.identity,
    required this.name,
    required this.isHost,
    required this.liveKitUrl,
    required this.liveKitToken,
  });

  factory SchedulerJoinResult.fromJson(Map<String, dynamic> json) =>
      SchedulerJoinResult(
        roomName: json['roomName'] as String? ?? '',
        identity: json['identity'] as String? ?? '',
        name: json['name'] as String? ?? '',
        isHost: json['isHost'] as bool? ?? false,
        liveKitUrl: json['liveKitUrl'] as String? ?? '',
        liveKitToken: json['liveKitToken'] as String? ?? '',
      );

  final String roomName;
  final String identity;
  final String name;
  final bool isHost;
  final String liveKitUrl;
  final String liveKitToken;
}

/// 调用房间接口失败的异常，message 可直接展示。
class RoomApiException implements Exception {
  RoomApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 仅用于测试：构造一个 RoomSummary。
@visibleForTesting
RoomSummary roomSummaryForTest({
  String id = 'r1',
  String title = '测试会议',
  RoomStatus status = RoomStatus.scheduled,
  String statusStr = '已预约',
  DateTime? startTime,
  DateTime? endTime,
  String hostUserId = 'u1',
}) =>
    RoomSummary(
      id: id,
      title: title,
      roomName: 'room-$id',
      hostUserId: hostUserId,
      hostNickname: '主持人',
      startTime: startTime ?? DateTime.now(),
      endTime: endTime ?? DateTime.now().add(const Duration(hours: 1)),
      maxParticipants: 50,
      status: status,
      statusStr: statusStr,
      locked: false,
      inviteCode: null,
      createdAt: DateTime.now(),
    );
