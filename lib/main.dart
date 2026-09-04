import 'package:flutter/material.dart';
import 'package:livekit_example/pages/meeting_workbench.dart';
import 'package:livekit_example/services/auth_service.dart';
import 'package:livekit_example/services/logger_service.dart';
import 'package:livekit_example/theme.dart';
import 'package:logging/logging.dart';
import 'pages/login.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化日志服务（控制台 + 文件双输出）。
  // 文件路径：可执行文件同级 logs/bobomeet_YYYYMMDD.log
  // 控制台与日志文件都按格式输出：时间 [级别] [标签] 消息 + 错误 + 堆栈
  await LoggerService.init(level: Level.FINEST);

  // 恢复本地登录会话（token / 管理平台地址）
  await AuthService.instance.restore();

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
            ? const MeetingWorkbenchPage()
            : const LoginPage(),
      );
}
