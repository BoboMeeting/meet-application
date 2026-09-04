import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:livekit_example/models/room_models.dart';
import 'package:livekit_example/services/room_service.dart';
import 'package:livekit_example/theme.dart';
import 'package:livekit_example/widgets/text_field.dart';

/// 预约会议表单页：填写主题、开始时间、时长、最大人数后调用 POST /api/rooms/create。
class CreateRoomPage extends StatefulWidget {
  const CreateRoomPage({super.key});

  @override
  State<CreateRoomPage> createState() => _CreateRoomPageState();
}

class _CreateRoomPageState extends State<CreateRoomPage> {
  final _titleCtrl = TextEditingController();
  final _inviteCtrl = TextEditingController();

  DateTime _start = DateTime.now().add(const Duration(minutes: 5));
  int _durationMinutes = 60;
  int _maxParticipants = 50;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _inviteCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickStartTime() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _start.isAfter(now) ? _start : now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 90)),
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_start),
    );
    if (time == null) return;
    final picked = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    setState(() => _start = picked);
  }

  Future<void> _submit() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _error = '请填写会议主题');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final room = await RoomService.instance.createRoom(
        title: title,
        startTime: _start,
        durationSeconds: _durationMinutes * 60,
        maxParticipants: _maxParticipants,
        inviteCode: _inviteCtrl.text.trim().isEmpty ? null : _inviteCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(room);
    } on RoomApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '预约失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('预约会议')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: LKColors.surface,
                    border: Border.all(color: LKColors.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LKTextField(
                        label: '会议主题',
                        ctrl: _titleCtrl,
                        icon: Icons.title,
                        textInputAction: TextInputAction.next,
                      ),
                      const SizedBox(height: 18),
                      // 开始时间
                      _LabelRow(
                        label: '开始时间',
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _pickStartTime,
                          icon: const Icon(Icons.event, size: 18),
                          label: Text(
                            DateFormat('yyyy-MM-dd HH:mm').format(_start),
                            style: const TextStyle(fontSize: 15),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      // 时长
                      _LabelRow(
                        label: '预计时长（分钟）',
                        child: Wrap(
                          spacing: 8,
                          children: [30, 60, 90, 120]
                              .map((m) => ChoiceChip(
                                    label: Text('$m'),
                                    selected: _durationMinutes == m,
                                    onSelected: _busy
                                        ? null
                                        : (v) => v
                                            ? setState(() => _durationMinutes = m)
                                            : null,
                                  ))
                              .toList(),
                        ),
                      ),
                      const SizedBox(height: 18),
                      // 最大人数
                      _LabelRow(
                        label: '最大参会人数（含 AI）',
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: _busy || _maxParticipants <= 2
                                  ? null
                                  : () => setState(
                                      () => _maxParticipants--),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                            Text('$_maxParticipants',
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w600)),
                            IconButton(
                              onPressed: _busy || _maxParticipants >= 200
                                  ? null
                                  : () => setState(
                                      () => _maxParticipants++),
                              icon: const Icon(Icons.add_circle_outline),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 18),
                      LKTextField(
                        label: '邀请码（可选，留空自动生成）',
                        ctrl: _inviteCtrl,
                        icon: Icons.confirmation_number,
                        textInputAction: TextInputAction.done,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _error!,
                          style: const TextStyle(
                              color: LKColors.destructiveDark, fontSize: 13),
                        ),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _busy ? null : _submit,
                        icon: _busy
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            : const Icon(Icons.add),
                        label: Text(_busy ? '提交中...' : '预约会议'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

class _LabelRow extends StatelessWidget {
  const _LabelRow({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                  color: LKColors.lkBlue, fontSize: 13),
            ),
          ),
          Expanded(child: child),
        ],
      );
}
