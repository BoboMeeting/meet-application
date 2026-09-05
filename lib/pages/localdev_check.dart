import 'dart:async';
import 'dart:math' as math;

import 'package:dropdown_button2/dropdown_button2.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/logger_service.dart' as log;
import '../theme.dart';
import '../utils.dart';

const _tag = 'PreJoin';

class JoinArgs {
  JoinArgs({
    required this.url,
    required this.token,
    this.e2ee = false,
    this.e2eeKey,
    this.simulcast = true,
    this.adaptiveStream = true,
    this.dynacast = true,
    this.autoSubscribe = true,
    this.preferredCodec = 'VP8',
    this.enableBackupVideoCodec = true,
  });
  final String url;
  final String token;
  final bool e2ee;
  final String? e2eeKey;
  final bool simulcast;
  final bool adaptiveStream;
  final bool dynacast;
  final bool autoSubscribe;
  final String preferredCodec;
  final bool enableBackupVideoCodec;
}

class LocalDevCheckPage extends StatefulWidget {
  const LocalDevCheckPage({super.key});
  @override
  State<StatefulWidget> createState() => _LocalDevCheckPageState();
}

class _LocalDevCheckPageState extends State<LocalDevCheckPage> {
  static const _prefKeyEnableVideo = 'prejoin-enable-video';
  static const _prefKeyEnableAudio = 'prejoin-enable-audio';

  List<MediaDevice> _audioInputs = [];
  List<MediaDevice> _videoInputs = [];
  StreamSubscription? _subscription;

  bool _enableVideo = true;
  bool _enableAudio = true;
  LocalAudioTrack? _audioTrack;
  LocalVideoTrack? _videoTrack;

  MediaDevice? _selectedVideoDevice;
  MediaDevice? _selectedAudioDevice;
  VideoParameters _selectedVideoParameters = VideoParametersPresets.h720_169;

  @override
  void initState() {
    super.initState();
    if (lkPlatformIsDesktop()) {
      onWindowShouldClose = () async {
        log.LoggerService.info('桌面端: 窗口关闭请求, 开始释放本地轨道', name: _tag);
        await _releaseLocalTracks();
      };
    }
    unawaited(_initStateAsync());
  }

  Future<void> _initStateAsync() async {
    log.LoggerService.info('PreJoinPage initState 开始', name: _tag);
      log.LoggerService.info('LocalDevCheckPage initState 开始', name: _tag);
      log.LoggerService.debug('LocalDevCheckPage initState 完成', name: _tag);
    try {
      await _readPrefs();
      log.LoggerService.debug(
        '读取偏好: enableVideo=$_enableVideo, enableAudio=$_enableAudio',
        name: _tag,
      );
      _subscription = Hardware.instance.onDeviceChange.stream.listen(
        _loadDevices,
      );
      final devices = await Hardware.instance.enumerateDevices();
      log.LoggerService.info(
        '设备枚举完成, 共 ${devices.length} 个设备',
        name: _tag,
      );
      await _loadDevices(devices);
      log.LoggerService.info('LocalDevCheckPage initState 完成', name: _tag);
    } catch (e, st) {
      log.LoggerService.error(
        'LocalDevCheckPage initState 异常',
        name: _tag,
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  void deactivate() {
    unawaited(_subscription?.cancel());
    super.deactivate();
  }

  Future<void> _loadDevices(List<MediaDevice> devices) async {
    _audioInputs = devices.where((d) => d.kind == 'audioinput').toList();
    _videoInputs = devices.where((d) => d.kind == 'videoinput').toList();
    log.LoggerService.debug(
      '加载设备: audioInputs=${_audioInputs.length}, videoInputs=${_videoInputs.length}',
      name: _tag,
    );

    if (_selectedAudioDevice != null && !_audioInputs.contains(_selectedAudioDevice)) {
      _selectedAudioDevice = null;
    }
    if (_audioInputs.isEmpty) {
      await _audioTrack?.stop();
      _audioTrack = null;
    }
    if (_selectedVideoDevice != null && !_videoInputs.contains(_selectedVideoDevice)) {
      _selectedVideoDevice = null;
    }
    if (_videoInputs.isEmpty) {
      await _videoTrack?.stop();
      _videoTrack = null;
    }

    if (_enableAudio && _audioInputs.isNotEmpty) {
      if (_selectedAudioDevice == null) {
        _selectedAudioDevice = _audioInputs.first;
        Future.delayed(const Duration(milliseconds: 100), () async {
          if (!mounted) return;
          await _changeLocalAudioTrack();
          if (mounted) setState(() {});
        });
      }
    }

    if (_enableVideo && _videoInputs.isNotEmpty) {
      if (_selectedVideoDevice == null) {
        _selectedVideoDevice = _videoInputs.first;
        Future.delayed(const Duration(milliseconds: 100), () async {
          if (!mounted) return;
          await _changeLocalVideoTrack();
          if (mounted) setState(() {});
        });
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _setEnableVideo(value) async {
    _enableVideo = value;
    await _writePrefs();
    if (!_enableVideo) {
      await _videoTrack?.stop();
      _videoTrack = null;
      _selectedVideoDevice = null;
    } else {
      if (_selectedVideoDevice == null && _videoInputs.isNotEmpty) {
        _selectedVideoDevice = _videoInputs.first;
      }
      await _changeLocalVideoTrack();
    }
    setState(() {});
  }

  Future<void> _setEnableAudio(value) async {
    _enableAudio = value;
    await _writePrefs();
    if (!_enableAudio) {
      await _audioTrack?.stop();
      _audioTrack = null;
      _selectedAudioDevice = null;
    } else {
      if (_selectedAudioDevice == null && _audioInputs.isNotEmpty) {
        _selectedAudioDevice = _audioInputs.first;
      }
      await _changeLocalAudioTrack();
    }
    setState(() {});
  }

  Future<void> _changeLocalAudioTrack() async {
    if (!_enableAudio) return;
    log.LoggerService.debug('创建本地音频轨道开始', name: _tag);
    if (_audioTrack != null) {
      await _audioTrack!.stop();
      _audioTrack = null;
      log.LoggerService.debug('已停止旧音频轨道', name: _tag);
    }

    if (_selectedAudioDevice != null) {
      try {
        _audioTrack = await LocalAudioTrack.create(
          AudioCaptureOptions(deviceId: _selectedAudioDevice!.deviceId),
        );
        await _audioTrack!.start();
        log.LoggerService.info(
          '本地音频轨道创建并启动成功, deviceId=${_selectedAudioDevice!.deviceId}',
          name: _tag,
        );
      } catch (e, st) {
        log.LoggerService.error(
          '本地音频轨道创建失败',
          name: _tag,
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  Future<void> _changeLocalVideoTrack() async {
    if (!_enableVideo) return;
    log.LoggerService.debug(
      '创建本地视频轨道开始, params=${_selectedVideoParameters.dimensions.width}'
      'x${_selectedVideoParameters.dimensions.height}',
      name: _tag,
    );
    if (_videoTrack != null) {
      await _videoTrack!.stop();
      _videoTrack = null;
      log.LoggerService.debug('已停止旧视频轨道', name: _tag);
    }

    if (_selectedVideoDevice != null) {
      try {
        _videoTrack = await LocalVideoTrack.createCameraTrack(
          CameraCaptureOptions(
            deviceId: _selectedVideoDevice!.deviceId,
            params: _selectedVideoParameters,
          ),
        );
        await _videoTrack!.start();
        log.LoggerService.info(
          '本地视频轨道创建并启动成功, deviceId=${_selectedVideoDevice!.deviceId}',
          name: _tag,
        );
      } catch (e, st) {
        log.LoggerService.error(
          '本地视频轨道创建失败',
          name: _tag,
          error: e,
          stackTrace: st,
        );
      }
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    onWindowShouldClose = null;
    unawaited(_releaseLocalTracks());
    super.dispose();
  }

  Future<void> _releaseLocalTracks() async {
    final audioTrack = _audioTrack;
    final videoTrack = _videoTrack;
    _audioTrack = null;
    _videoTrack = null;

    try {
      await audioTrack?.stop();
    } catch (e, st) {
      log.LoggerService.error(
        '释放本地音频轨道失败',
        name: _tag,
        error: e,
        stackTrace: st,
      );
    }
    try {
      await videoTrack?.stop();
    } catch (e, st) {
      log.LoggerService.error(
        '释放本地视频轨道失败',
        name: _tag,
        error: e,
        stackTrace: st,
      );
    }
    log.LoggerService.info('本地 LiveKit Track 释放完成', name: _tag);
  }

  void _actionBack(BuildContext context) async {
    log.LoggerService.info('返回: 停止本地轨道并退出 PreJoinPage', name: _tag);
      log.LoggerService.info('返回: 停止本地轨道并退出 LocalDevCheckPage', name: _tag);
    await _setEnableVideo(false);
    await _setEnableAudio(false);
    if (!context.mounted) return;
    Navigator.of(context).pop();
  }

  Future<void> _readPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _enableVideo = prefs.getBool(_prefKeyEnableVideo) ?? true;
      _enableAudio = prefs.getBool(_prefKeyEnableAudio) ?? true;
    });
  }

  Future<void> _writePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyEnableVideo, _enableVideo);
    await prefs.setBool(_prefKeyEnableAudio, _enableAudio);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Select Devices',
          style: TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => _actionBack(context),
        ),
      ),
      body: Container(
        alignment: Alignment.center,
        child: SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: SizedBox(
                    width: 320,
                    height: 240,
                    child: Container(
                      alignment: Alignment.center,
                      color: Colors.black54,
                      child: _videoTrack != null
                          ? VideoTrackRenderer(
                              renderMode: VideoRenderMode.auto,
                              _videoTrack!,
                            )
                          : Container(
                              alignment: Alignment.center,
                              child: LayoutBuilder(
                                builder: (ctx, constraints) => Icon(
                                  Icons.videocam_off,
                                  color: LKColors.lkBlue,
                                  size: math.min(
                                        constraints.maxHeight,
                                        constraints.maxWidth,
                                      ) *
                                      0.3,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Camera:'),
                      Switch(
                        value: _enableVideo,
                        onChanged: (value) => _setEnableVideo(value),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 25),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton2<MediaDevice>(
                      isExpanded: true,
                      disabledHint: const Text('Disable Camera'),
                      hint: const Text('Select Camera'),
                      items: _enableVideo
                          ? _videoInputs
                              .map(
                                (MediaDevice item) => DropdownMenuItem<MediaDevice>(
                                  value: item,
                                  child: Text(
                                    item.label,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                              )
                              .toList()
                          : [],
                      value: _selectedVideoDevice,
                      onChanged: (MediaDevice? value) async {
                        if (value != null) {
                          _selectedVideoDevice = value;
                          await _changeLocalVideoTrack();
                          setState(() {});
                        }
                      },
                      buttonStyleData: const ButtonStyleData(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        height: 40,
                        width: 140,
                      ),
                      menuItemStyleData: const MenuItemStyleData(height: 40),
                    ),
                  ),
                ),
                if (_enableVideo)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 25),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton2<VideoParameters>(
                        isExpanded: true,
                        hint: const Text('Select Video Dimensions'),
                        items: [
                          VideoParametersPresets.h480_43,
                          VideoParametersPresets.h540_169,
                          VideoParametersPresets.h720_169,
                          VideoParametersPresets.h1080_169,
                        ]
                            .map(
                              (
                                VideoParameters item,
                              ) =>
                                  DropdownMenuItem<VideoParameters>(
                                value: item,
                                child: Text(
                                  '${item.dimensions.width}x${item.dimensions.height}',
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            )
                            .toList(),
                        value: _selectedVideoParameters,
                        onChanged: (VideoParameters? value) async {
                          if (value != null) {
                            _selectedVideoParameters = value;
                            await _changeLocalVideoTrack();
                            setState(() {});
                          }
                        },
                        buttonStyleData: const ButtonStyleData(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          height: 40,
                          width: 140,
                        ),
                        menuItemStyleData: const MenuItemStyleData(height: 40),
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Microphone:'),
                      Switch(
                        value: _enableAudio,
                        onChanged: (value) => _setEnableAudio(value),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 25),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton2<MediaDevice>(
                      isExpanded: true,
                      disabledHint: const Text('Disable Microphone'),
                      hint: const Text('Select Microphone'),
                      items: _enableAudio
                          ? _audioInputs
                              .map(
                                (MediaDevice item) => DropdownMenuItem<MediaDevice>(
                                  value: item,
                                  child: Text(
                                    item.label,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ),
                              )
                              .toList()
                          : [],
                      value: _selectedAudioDevice,
                      onChanged: (MediaDevice? value) async {
                        if (value != null) {
                          _selectedAudioDevice = value;
                          await _changeLocalAudioTrack();
                          setState(() {});
                        }
                      },
                      buttonStyleData: const ButtonStyleData(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        height: 40,
                        width: 140,
                      ),
                      menuItemStyleData: const MenuItemStyleData(height: 40),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
