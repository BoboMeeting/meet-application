import 'package:flutter/material.dart';
import 'package:livekit_example/services/auth_service.dart';
import 'package:livekit_example/theme.dart';
import 'package:logging/logging.dart';
import 'package:intl/intl.dart';
import 'pages/connect.dart';
import 'pages/login.dart';

void main() async {
  final format = DateFormat('HH:mm:ss');
  // configure logs for debugging
  Logger.root.level = Level.FINEST;
  Logger.root.onRecord.listen((record) {
    print('${format.format(record.time)} [${record.level.name}]: ${record.message}');
  });

  WidgetsFlutterBinding.ensureInitialized();

  // 恢复本地登录会话（token / 管理平台地址）
  await AuthService.instance.restore();

  /*if (lkPlatformIsDesktop()) {
    await FlutterWindowClose.setWindowShouldCloseHandler(() async {
      await onWindowShouldClose?.call();
      return true;
    });
  }*/

  /// for livestreaming app, you can initialize the bypassVoiceProcessing = true
  /// here to get better audio quality
  ///
  /// await LiveKitClient.initialize(
  ///  bypassVoiceProcessing: lkPlatformIsMobile(),
  /// );
  runApp(const LiveKitExampleApp());
}

class LiveKitExampleApp extends StatelessWidget {
  //
  const LiveKitExampleApp({
    super.key,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LiveKit Flutter Example',
        theme: LiveKitTheme().buildThemeData(context),
        home: AuthService.instance.isLoggedIn
            ? const ConnectPage()
            : const LoginPage(),
      );
}
