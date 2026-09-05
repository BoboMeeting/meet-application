import 'dart:async';

import 'package:flutter/material.dart';

import 'package:livekit_client/livekit_client.dart';

class ConnectionCheckPage extends StatefulWidget {
  //
  const ConnectionCheckPage({super.key});

  @override
  State<StatefulWidget> createState() => _ConnectionCheckPageState();
}

class _ConnectionCheckPageState extends State<ConnectionCheckPage> {
  //
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  ConnectionCheck? _connectionCheck;
  EventsListener<ConnectionCheckEvent>? _listener;
  final Map<int, CheckInfo> _results = {};
  bool _running = false;

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    unawaited(_cleanUp());
    super.dispose();
  }

  Future<void> _cleanUp() async {
    await _listener?.dispose();
    _listener = null;
    await _connectionCheck?.dispose();
    _connectionCheck = null;
  }

  Future<void> _runChecks() async {
    if (_urlController.text.trim().isEmpty || _tokenController.text.trim().isEmpty) {
      await _openSettings();
      if (_urlController.text.trim().isEmpty || _tokenController.text.trim().isEmpty) {
        return;
      }
    }

    await _cleanUp();

    final connectionCheck = ConnectionCheck(
      _urlController.text.trim(),
      _tokenController.text.trim(),
    );
    final listener = connectionCheck.createListener();
    listener.on<ConnectionCheckUpdateEvent>((event) {
      if (!mounted) return;
      setState(() {
        _results[event.checkId] = event.info;
      });
    });

    setState(() {
      _connectionCheck = connectionCheck;
      _listener = listener;
      _results.clear();
      _running = true;
    });

    final checks = <Future<CheckInfo> Function()>[
      connectionCheck.checkWebsocket,
      connectionCheck.checkWebRTC,
      connectionCheck.checkTURN,
      connectionCheck.checkReconnect,
      connectionCheck.checkPublishAudio,
      connectionCheck.checkPublishVideo,
      connectionCheck.checkConnectionProtocol,
      connectionCheck.checkCloudRegion,
    ];
    try {
      for (final check in checks) {
        // stop starting new checks once the page is gone
        if (!mounted) break;
        await check();
      }
    } catch (error) {
      print('Connection check error: $error');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  Future<void> _openSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('连接检查设置'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _urlController,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  hintText: 'wss://your-livekit-server',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _tokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'TOKEN',
                  hintText: 'LiveKit access token',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              if (_urlController.text.trim().isEmpty || _tokenController.text.trim().isEmpty) {
                return;
              }
              Navigator.of(context).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _iconFor(CheckStatus status) {
    switch (status) {
      case CheckStatus.idle:
        return const Icon(Icons.radio_button_unchecked);
      case CheckStatus.running:
        return const SizedBox(
          width: 24,
          height: 24,
          child: Padding(
            padding: EdgeInsets.all(2),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case CheckStatus.skipped:
        return const Icon(Icons.skip_next, color: Colors.grey);
      case CheckStatus.success:
        return const Icon(Icons.check_circle, color: Colors.green);
      case CheckStatus.failed:
        return const Icon(Icons.error, color: Colors.red);
    }
  }

  Color _colorFor(CheckLogLevel level) {
    switch (level) {
      case CheckLogLevel.info:
        return Colors.grey;
      case CheckLogLevel.warning:
        return Colors.orange;
      case CheckLogLevel.error:
        return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    final results = _results.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Check'),
        actions: [
          IconButton(
            onPressed: _running ? null : _openSettings,
            tooltip: '设置 URL 和 TOKEN',
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                for (final entry in results)
                  ExpansionTile(
                    initiallyExpanded: true,
                    leading: _iconFor(entry.value.status),
                    title: Text(entry.value.name),
                    subtitle: Text(entry.value.description),
                    children: [
                      for (final log in entry.value.logs)
                        ListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          title: Text(
                            log.message,
                            style: TextStyle(
                              fontSize: 13,
                              color: _colorFor(log.level),
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ElevatedButton(
                onPressed: _running ? null : () => unawaited(_runChecks()),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_running)
                      const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: SizedBox(
                          height: 15,
                          width: 15,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        ),
                      ),
                    const Text('Run checks'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
