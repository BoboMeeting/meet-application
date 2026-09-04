import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:livekit_example/services/auth_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final auth = AuthService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    auth.resetForTesting();
  });

  group('normalizeBaseUrl', () {
    test('空字符串返回 null', () {
      expect(AuthService.normalizeBaseUrl(''), isNull);
      expect(AuthService.normalizeBaseUrl('   '), isNull);
    });

    test('未带协议时自动补全 http://', () {
      expect(
        AuthService.normalizeBaseUrl('192.168.1.10:5000'),
        'http://192.168.1.10:5000',
      );
      expect(
        AuthService.normalizeBaseUrl('localhost:5000'),
        'http://localhost:5000',
      );
    });

    test('已带协议时保持不变', () {
      expect(
        AuthService.normalizeBaseUrl('https://meet.example.com'),
        'https://meet.example.com',
      );
      expect(
        AuthService.normalizeBaseUrl('http://localhost:5000'),
        'http://localhost:5000',
      );
    });

    test('去除末尾斜杠与空白', () {
      expect(
        AuthService.normalizeBaseUrl('  http://localhost:5000/  '),
        'http://localhost:5000',
      );
    });

    test('非法地址返回 null', () {
      expect(AuthService.normalizeBaseUrl('http://'), isNull);
    });
  });

  group('login', () {
    test('登录成功：返回用户信息并持久化 token', () async {
      http.Request? captured;
      auth.debugHttpClient = MockClient((request) async {
        captured = request;
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
      });

      final user = await auth.login(
        baseUrl: 'http://localhost:5000/',
        account: 'alice',
        password: 'secret123',
      );

      // 请求契约校验
      expect(captured, isNotNull);
      expect(captured!.method, 'POST');
      expect(captured!.url, Uri.parse('http://localhost:5000/api/auth/login'));
      final reqBody = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(reqBody['account'], 'alice');
      expect(reqBody['password'], 'secret123');

      // 返回与内存状态
      expect(user.id, 'u-001');
      expect(user.nickname, 'Alice');
      expect(auth.isLoggedIn, isTrue);
      expect(auth.accessToken, 'jwt-token-abc');
      expect(auth.baseUrl, 'http://localhost:5000');

      // 已持久化到本地存储
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth-access-token'), 'jwt-token-abc');
      expect(prefs.getString('auth-base-url'), 'http://localhost:5000');
      expect(prefs.getString('auth-account'), 'alice');
      final savedUser = jsonDecode(prefs.getString('auth-user')!) as Map<String, dynamic>;
      expect(savedUser['id'], 'u-001');
      expect(savedUser['nickname'], 'Alice');
    });

    test('401：抛出后端返回的中文错误信息且不保持登录', () async {
      auth.debugHttpClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'error': '账号或密码错误'}),
          401,
          headers: {'content-type': 'application/json'},
        );
      });

      try {
        await auth.login(baseUrl: 'http://localhost:5000', account: 'alice', password: 'wrong');
        fail('应抛出 AuthException');
      } on AuthException catch (e) {
        expect(e.message, '账号或密码错误');
      }
      expect(auth.isLoggedIn, isFalse);
      expect(auth.accessToken, isNull);
    });

    test('400 校验失败：展示后端 error 字段', () async {
      auth.debugHttpClient = MockClient((request) async {
        return http.Response(
          jsonEncode({'error': 'account/password 必填'}),
          400,
          headers: {'content-type': 'application/json'},
        );
      });

      expect(
        () => auth.login(baseUrl: 'http://localhost:5000', account: '', password: ''),
        throwsA(isA<AuthException>()),
      );
    });

    test('网络不可达：抛出连接失败提示', () async {
      auth.debugHttpClient = MockClient((request) async {
        throw Exception('connection refused');
      });

      try {
        await auth.login(baseUrl: 'http://localhost:5000', account: 'alice', password: 'secret123');
        fail('应抛出 AuthException');
      } on AuthException catch (e) {
        expect(e.message, contains('无法连接管理平台'));
      }
      expect(auth.isLoggedIn, isFalse);
    });

    test('URL 非法时直接报错且不发请求', () async {
      var called = false;
      auth.debugHttpClient = MockClient((request) async {
        called = true;
        return http.Response('{}', 200);
      });

      try {
        await auth.login(baseUrl: '', account: 'alice', password: 'secret123');
        fail('应抛出 AuthException');
      } on AuthException catch (e) {
        expect(e.message, contains('管理平台 URL'));
      }
      expect(called, isFalse);
    });
  });

  group('saveBaseUrl / restore / logout', () {
    test('saveBaseUrl 独立保存地址，不依赖登录', () async {
      final saved = await auth.saveBaseUrl('192.168.1.20:6000/');
      expect(saved, 'http://192.168.1.20:6000');
      expect(auth.baseUrl, 'http://192.168.1.20:6000');
      expect(auth.isLoggedIn, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth-base-url'), 'http://192.168.1.20:6000');
    });

    test('saveBaseUrl 非法地址抛异常', () async {
      expect(
        () => auth.saveBaseUrl(''),
        throwsA(isA<AuthException>()),
      );
    });

    test('restore 从本地恢复登录会话', () async {
      SharedPreferences.setMockInitialValues({
        'auth-base-url': 'http://meet.example.com',
        'auth-access-token': 'saved-jwt',
        'auth-account': 'bob',
        'auth-user': jsonEncode({
          'id': 'u-002',
          'account': 'bob',
          'nickname': 'Bob',
          'avatarUrl': null,
          'role': 3,
          'status': 0,
        }),
      });

      await auth.restore();

      expect(auth.isLoggedIn, isTrue);
      expect(auth.accessToken, 'saved-jwt');
      expect(auth.baseUrl, 'http://meet.example.com');
      expect(auth.lastAccount, 'bob');
      expect(auth.user?.id, 'u-002');
      expect(auth.user?.role, '3');
    });

    test('restore 无本地数据时为未登录', () async {
      await auth.restore();
      expect(auth.isLoggedIn, isFalse);
      expect(auth.user, isNull);
    });

    test('logout 清除内存与本地会话', () async {
      SharedPreferences.setMockInitialValues({
        'auth-base-url': 'http://meet.example.com',
        'auth-access-token': 'saved-jwt',
        'auth-user': jsonEncode({'id': 'u-002', 'account': 'bob', 'nickname': 'Bob'}),
      });
      await auth.restore();
      expect(auth.isLoggedIn, isTrue);

      await auth.logout();

      expect(auth.isLoggedIn, isFalse);
      expect(auth.accessToken, isNull);
      expect(auth.user, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('auth-access-token'), isNull);
      expect(prefs.getString('auth-user'), isNull);
    });
  });
}
