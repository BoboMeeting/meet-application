import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:livekit_example/models/room_models.dart';
import 'package:livekit_example/pages/create_room_page.dart';
import 'package:livekit_example/pages/login.dart';
import 'package:livekit_example/pages/prejoin.dart';
import 'package:livekit_example/services/auth_service.dart';
import 'package:livekit_example/services/logger_service.dart' as log;
import 'package:livekit_example/services/room_service.dart';
import 'package:livekit_example/theme.dart';

const _tag = 'Workbench';

/// 会议工作台（首页）：登录后展示当前用户的会议列表，可预约、加入。
///
/// 设计参考：产品设计/会议工作台.md
/// 调用接口：RoomEndpoints（GET /api/rooms/、POST /api/rooms/create、GET /api/rooms/{id}/join）
class MeetingWorkbenchPage extends StatefulWidget {
  const MeetingWorkbenchPage({super.key});

  @override
  State<MeetingWorkbenchPage> createState() => _MeetingWorkbenchPageState();
}

class _MeetingWorkbenchPageState extends State<MeetingWorkbenchPage> {
  List<RoomSummary> _rooms = [];
  bool _loading = true;
  String? _error;
  bool _showHistory = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRooms());
  }

  Future<void> _loadRooms() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    log.LoggerService.info('刷新会议列表', name: _tag);
    try {
      final rooms = await RoomService.instance.listMyRooms();
      if (!mounted) return;
      log.LoggerService.info('加载完成，共 ${rooms.length} 个房间', name: _tag);
      setState(() {
        _rooms = rooms;
        _loading = false;
      });
    } on RoomApiException catch (e) {
      log.LoggerService.warning('加载房间列表失败(业务): ${e.message}', name: _tag);
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (e, st) {
      log.LoggerService.error(
        '加载房间列表异常',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _error = '加载失败：$e';
        _loading = false;
      });
    }
  }

  List<RoomSummary> get _filtered => _showHistory
      ? _rooms.where((r) => r.isHistory).toList()
      : _rooms.where((r) => !r.isHistory).toList();

  Future<void> _openCreatePage() async {
    final created = await Navigator.of(context).push<RoomSummary>(
      MaterialPageRoute(builder: (_) => const CreateRoomPage()),
    );
    if (created != null) {
      await _loadRooms();
    }
  }

  Future<void> _joinRoom(RoomSummary room) async {
    log.LoggerService.info(
      '用户点击加入会议 roomId=${room.id} title="${room.title}" status=${room.statusStr} locked=${room.locked}',
      name: _tag,
    );
    // 未开始的会议二次确认
    if (room.status == RoomStatus.scheduled ||
        (room.status == RoomStatus.open && !room.isInProgress)) {
      final confirmed = await _confirm(
        title: '会议尚未开始',
        message: '会议尚未开始，是否现在进入？',
        confirmText: '进入会议',
      );
      if (confirmed != true) {
        log.LoggerService.info('用户取消加入  roomId=${room.id}', name: _tag);
        return;
      }
    }

    if (room.locked) {
      if (!mounted) return;
      log.LoggerService.warning('房间已锁定，拒绝加入  roomId=${room.id}', name: _tag);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('房间已锁定，无法加入')),
      );
      return;
    }

    final totalSw = Stopwatch()..start();
    try {
      // 入会第一步：调管理平台 → 获取调度服务地址 + RoomTicket
      final nickname = AuthService.instance.user?.nickname;
      log.LoggerService.info('[入会UI] Step1 → 请求管理平台 roomId=${room.id} nickname=$nickname', name: _tag);
      final joinStep1 = await RoomService.instance
          .joinRoom(room.id, nickname: nickname);

      // 入会第二步：调调度服务 → 用 JWT + Ticket 换取 LiveKit 参数
      log.LoggerService.info(
        '[入会UI] Step2 → 请求调度服务 scheduler=${joinStep1.schedulerUrl}',
        name: _tag,
      );
      final lkParams = await RoomService.instance.exchangeSchedulerJoin(
        schedulerUrl: joinStep1.schedulerUrl,
        roomTicket: joinStep1.roomTicket,
      );

      // 跳转到 prejoin 页面，携带 liveKit URL 与 Token
      if (!mounted) return;
      totalSw.stop();
      log.LoggerService.info(
        '[入会UI] 两步骤完成，跳转 PreJoinPage  total=${totalSw.elapsedMilliseconds}ms  liveKitUrl=${lkParams.liveKitUrl}',
        name: _tag,
      );
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PreJoinPage(
            args: JoinArgs(
              url: lkParams.liveKitUrl,
              token: lkParams.liveKitToken,
            ),
          ),
        ),
      );
    } on RoomApiException catch (e) {
      totalSw.stop();
      log.LoggerService.warning(
        '[入会UI] 业务异常 total=${totalSw.elapsedMilliseconds}ms  msg=${e.message}',
        name: _tag,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e, st) {
      totalSw.stop();
      log.LoggerService.error(
        '[入会UI] 未预期异常 total=${totalSw.elapsedMilliseconds}ms',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('入会失败：$e')));
    }
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmText,
  }) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmText),
            ),
          ],
        ),
      );

  Future<void> _logout() async {
    await AuthService.instance.logout();
    if (!mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('会议工作台'),
          actions: [
            // 历史会议切换
            TextButton.icon(
              onPressed: () => setState(() => _showHistory = !_showHistory),
              icon: Icon(
                _showHistory ? Icons.history : Icons.history_toggle_off,
                size: 18,
              ),
              label: Text(_showHistory ? '历史会议' : '返回进行中'),
            ),
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'logout') unawaited(_logout());
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'logout', child: Text('退出登录')),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.person_outline, size: 20),
                  const SizedBox(width: 6),
                  Text(AuthService.instance.user?.nickname ?? '未登录'),
                  const Icon(Icons.arrow_drop_down, size: 20),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: !_showHistory
            ? FloatingActionButton.extended(
                onPressed: _openCreatePage,
                icon: const Icon(Icons.add),
                label: const Text('预约会议'),
              )
            : null,
        body: RefreshIndicator(
          onRefresh: _loadRooms,
          child: _buildBody(),
        ),
      );

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _loadRooms);
    }

    final list = _filtered;
    // 进行中强提醒横幅（仅非历史视图）
    final inProgress = _rooms.where((r) => r.isInProgress).toList();
    final showBanner = !_showHistory && inProgress.isNotEmpty;

    if (list.isEmpty) {
      return _EmptyState(
        isHistory: _showHistory,
        onCreate: _showHistory ? null : _openCreatePage,
      );
    }

    return ListView(
      // 即使内容不足也允许下拉刷新
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      children: [
        if (showBanner) ...[
          _InProgressBanner(
            room: inProgress.first,
            onJoin: () => _joinRoom(inProgress.first),
          ),
          const SizedBox(height: 12),
        ],
        ...list.map((r) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _RoomCard(
                room: r,
                currentUserId: AuthService.instance.user?.id ?? '',
                onJoin: () => _joinRoom(r),
              ),
            )),
      ],
    );
  }
}

/// 进行中横幅：列表顶部强提醒当前正有一场会议进行。
class _InProgressBanner extends StatelessWidget {
  const _InProgressBanner({required this.room, required this.onJoin});
  final RoomSummary room;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: LKColors.emerald400.withValues(alpha: 0.12),
          border: Border.all(color: LKColors.emerald400.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const _BreathingDot(color: LKColors.emerald400),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${room.title} 正在进行中',
                style: const TextStyle(
                    color: LKColors.emerald400, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: onJoin,
              child: const Text('加入'),
            ),
          ],
        ),
      );
}

/// 绿色呼吸灯动画点。
class _BreathingDot extends StatefulWidget {
  const _BreathingDot({required this.color});
  final Color color;

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) => Opacity(
          opacity: 0.4 + 0.6 * _ctrl.value,
          child: child,
        ),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
        ),
      );
}

/// 会议卡片：状态徽章 + 主题/时间/主持人 + 加入按钮。
class _RoomCard extends StatelessWidget {
  const _RoomCard({
    required this.room,
    required this.currentUserId,
    required this.onJoin,
  });
  final RoomSummary room;
  final String currentUserId;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final badge = _statusBadge(room, now);
    final isHost = room.isHostBy(currentUserId);
    final timeFmt = DateFormat('HH:mm');
    final dateFmt = DateFormat('MM-dd');

    return Container(
      decoration: BoxDecoration(
        color: LKColors.surface,
        border: Border.all(color: LKColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onJoin,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: badge.color.withValues(alpha: 0.15),
                          border: Border.all(
                              color: badge.color.withValues(alpha: 0.6)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (room.isInProgress)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: _BreathingDot(
                                    color: LKColors.emerald400),
                              ),
                            Text(
                              badge.label,
                              style: TextStyle(
                                  color: badge.color, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${dateFmt.format(room.startTime)} ${timeFmt.format(room.startTime)} - ${timeFmt.format(room.endTime)}',
                        style: const TextStyle(
                            color: LKColors.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    room.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.tag, size: 14, color: LKColors.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          room.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: LKColors.textSecondary, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        isHost ? Icons.star : Icons.person,
                        size: 14,
                        color: isHost
                            ? LKColors.lkGreen
                            : LKColors.textSecondary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${room.hostNickname}${isHost ? '（我）' : ''}',
                        style: const TextStyle(
                            color: LKColors.textSecondary, fontSize: 13),
                      ),
                      if (room.locked) ...[
                        const SizedBox(width: 12),
                        const Icon(Icons.lock,
                            size: 13, color: LKColors.destructiveDark),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: LKColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                if (room.maxParticipants > 0)
                  Text(
                    '上限 ${room.maxParticipants} 人',
                    style: const TextStyle(
                        color: LKColors.textSecondary, fontSize: 12),
                  ),
                const Spacer(),
                _JoinButton(room: room, onJoin: onJoin),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _JoinButton extends StatelessWidget {
  const _JoinButton({required this.room, required this.onJoin});
  final RoomSummary room;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    // 历史会议（已结束/已取消）不可加入
    if (room.isHistory) {
      return ElevatedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.check, size: 16),
        label: const Text('已结束'),
      );
    }
    return ElevatedButton.icon(
      onPressed: onJoin,
      icon: const Icon(Icons.login, size: 16),
      label: const Text('加入会议'),
    );
  }
}

/// 根据房间状态计算徽章文案与颜色。
_StatusBadge _statusBadge(RoomSummary r, DateTime now) {
  switch (r.status) {
    case RoomStatus.scheduled:
      // 已预约但距开始不足 15 分钟 → 即将开始
      if (r.isStartingSoon(now)) {
        return const _StatusBadge('即将开始', Colors.amber);
      }
      return _StatusBadge(
          r.statusStr.isEmpty ? '已预约' : r.statusStr, LKColors.lkAccentDark);
    case RoomStatus.open:
      if (r.isInProgress) {
        return const _StatusBadge('进行中', LKColors.emerald400);
      }
      if (r.isStartingSoon(now)) {
        return const _StatusBadge('即将开始', Colors.amber);
      }
      return _StatusBadge(
          r.statusStr.isEmpty ? '待开始' : r.statusStr, LKColors.textSecondary);
    case RoomStatus.closed:
      return const _StatusBadge('会议已结束', LKColors.textSecondary);
    case RoomStatus.cancelled:
      return const _StatusBadge('会议已取消', LKColors.destructiveDark);
  }
}

/// 状态徽章：文案 + 颜色。
class _StatusBadge {
  const _StatusBadge(this.label, this.color);
  final String label;
  final Color color;
}

/// 空状态。
class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isHistory, this.onCreate});
  final bool isHistory;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isHistory ? Icons.history : Icons.event_busy,
              size: 72,
              color: LKColors.textSecondary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              isHistory ? '暂无历史会议' : '今天没有安排，休息一下吧',
              style: const TextStyle(
                  color: LKColors.textSecondary, fontSize: 15),
            ),
            if (!isHistory && onCreate != null) ...[
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.add),
                label: const Text('预约会议'),
              ),
            ],
          ],
        ),
      );
}

/// 错误视图。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline,
                size: 56, color: LKColors.destructiveDark),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
}
