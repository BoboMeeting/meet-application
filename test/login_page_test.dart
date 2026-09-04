import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:livekit_example/main.dart';
import 'package:livekit_example/services/auth_service.dart';
import 'package:livekit_example/services/room_service.dart';
import 'package:livekit_example/widgets/text_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 找到指定标签的 LKTextField 内部的 TextField。
Finder _textFieldIn(String label) => find.descendant(
      of: find.widgetWithText(LKTextField, label),
      matching: find.byType(TextField),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final auth = AuthService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    auth.resetForTesting();
  });

  testWidgets('登录页展示用户名 / 密码输入框与登录、配置按钮', (tester) async {
    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('登录管理平台'), findsOneWidget);
    expect(find.widgetWithText(LKTextField, '用户名'), findsOneWidget);
    expect(find.widgetWithText(LKTextField, '密码'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, '登录'), findsOneWidget);
    expect(find.byTooltip('配置管理平台地址'), findsOneWidget);
  });

  testWidgets('密码输入框默认掩码，点击眼睛图标可切换明文', (tester) async {
    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(_textFieldIn('密码')).obscureText, isTrue);

    await tester.tap(find.byTooltip('显示密码'));
    await tester.pump();
    expect(tester.widget<TextField>(_textFieldIn('密码')).obscureText, isFalse);

    await tester.tap(find.byTooltip('隐藏密码'));
    await tester.pump();
    expect(tester.widget<TextField>(_textFieldIn('密码')).obscureText, isTrue);
  });

  testWidgets('未配置平台地址时点登录，提示前往设置配置', (tester) async {
    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    await tester.enterText(_textFieldIn('用户名'), 'alice');
    await tester.enterText(_textFieldIn('密码'), 'secret123');
    await tester.tap(find.widgetWithText(ElevatedButton, '登录'));
    await tester.pump();

    expect(find.text('请先在设置中配置管理平台地址'), findsOneWidget);
  });

  testWidgets('账号或密码错误时，行内展示后端返回的错误信息', (tester) async {
    await auth.saveBaseUrl('http://localhost:5000');
    auth.debugHttpClient = MockClient((request) async {
      return http.Response(
        jsonEncode({'error': '账号或密码错误'}),
        401,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    await tester.enterText(_textFieldIn('用户名'), 'alice');
    await tester.enterText(_textFieldIn('密码'), 'wrong-pwd');
    await tester.tap(find.widgetWithText(ElevatedButton, '登录'));
    await tester.pumpAndSettle();

    expect(find.text('账号或密码错误'), findsOneWidget);
    // 仍停留在登录页
    expect(find.text('登录管理平台'), findsOneWidget);
  });

  testWidgets('登录成功后跳转到会议工作台', (tester) async {
    final capturedUrls = <Uri>[];
    final mockClient = MockClient((request) async {
      capturedUrls.add(request.url);
      // 登录接口返回成功；房间列表接口返回空数组
      if (request.url.path.endsWith('/api/auth/login')) {
        return http.Response(
          jsonEncode({
            'accessToken': 'jwt-token-abc',
            'expiresInSeconds': 7200,
            'user': {
              'id': 'u-001',
              'account': 'alice',
              'nickname': 'Alice',
              'avatarUrl': null,
              'role': 0,
              'status': 0,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      // 其它接口（如房间列表）返回空数组
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json'});
    });
    auth.debugHttpClient = mockClient;
    RoomService.instance.debugHttpClient = mockClient;
    await auth.saveBaseUrl('localhost:5000/');

    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    await tester.enterText(_textFieldIn('用户名'), 'alice');
    await tester.enterText(_textFieldIn('密码'), 'secret123');
    await tester.tap(find.widgetWithText(ElevatedButton, '登录'));
    await tester.pumpAndSettle();

    // 登录请求发往规范化后的地址
    expect(capturedUrls,
        contains(Uri.parse('http://localhost:5000/api/auth/login')));

    // 已进入会议工作台
    expect(find.text('会议工作台'), findsOneWidget);
    expect(find.text('登录管理平台'), findsNothing);
  });

  testWidgets('配置弹窗可保存管理平台地址并持久化', (tester) async {
    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    // 打开配置弹窗
    await tester.tap(find.byTooltip('配置管理平台地址'));
    await tester.pumpAndSettle();
    expect(find.text('配置管理平台地址'), findsOneWidget);

    // 输入地址并保存
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, '192.168.1.20:6000/');
    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pumpAndSettle();

    // 弹窗关闭，提示成功
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('管理平台地址已保存'), findsOneWidget);

    // 未登录但地址已持久化
    expect(auth.isLoggedIn, isFalse);
    expect(auth.baseUrl, 'http://192.168.1.20:6000');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('auth-base-url'), 'http://192.168.1.20:6000');
  });

  testWidgets('配置弹窗中输入非法地址时显示错误且不关闭', (tester) async {
    await tester.pumpWidget(const LiveKitExampleApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('配置管理平台地址'));
    await tester.pumpAndSettle();

    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(dialogField, 'http://');
    await tester.tap(find.widgetWithText(ElevatedButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('请输入正确的管理平台 URL'), findsOneWidget);
  });
}
