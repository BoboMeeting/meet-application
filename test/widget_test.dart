import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:livekit_example/main.dart';
import 'package:livekit_example/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final auth = AuthService.instance;

  testWidgets('未登录时启动显示登录界面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    auth.resetForTesting();

    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('登录管理平台'), findsOneWidget);
    expect(find.text('Connect to a room'), findsNothing);
  });

  testWidgets('已登录时启动直接显示会议连接界面', (tester) async {
    SharedPreferences.setMockInitialValues({
      'auth-base-url': 'http://localhost:5000',
      'auth-access-token': 'saved-jwt',
    });
    auth.resetForTesting();
    await auth.restore();

    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('Connect to a room'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Token'), findsOneWidget);
    expect(find.text('E2EE Key'), findsOneWidget);
    expect(find.text('CONNECT'), findsOneWidget);
  });
}
