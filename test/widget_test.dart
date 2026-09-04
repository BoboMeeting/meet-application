import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:livekit_example/main.dart';
import 'package:livekit_example/services/auth_service.dart';
import 'package:livekit_example/services/room_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final auth = AuthService.instance;

  testWidgets('未登录时启动显示登录界面', (tester) async {
    SharedPreferences.setMockInitialValues({});
    auth.resetForTesting();
    RoomService.instance.debugHttpClient = MockClient((_) async =>
        http.Response('[]', 200,
            headers: {'content-type': 'application/json'}));

    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('登录管理平台'), findsOneWidget);
    expect(find.text('会议工作台'), findsNothing);
  });

  testWidgets('已登录时启动直接显示会议工作台', (tester) async {
    SharedPreferences.setMockInitialValues({
      'auth-base-url': 'http://localhost:5000',
      'auth-access-token': 'saved-jwt',
    });
    auth.resetForTesting();
    await auth.restore();
    // 房间列表返回空数组，避免真实网络请求
    RoomService.instance.debugHttpClient = MockClient((_) async =>
        http.Response('[]', 200,
            headers: {'content-type': 'application/json'}));

    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('会议工作台'), findsOneWidget);
    expect(find.text('登录管理平台'), findsNothing);
  });
}
