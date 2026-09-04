import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'logger_service.dart' as log;

/// 登录失败异常，message 可直接展示给用户。
class AuthException implements Exception {
  AuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 登录用户信息（对应管理平台 UserInfo）。
///
/// 后端 Role/Status 枚举默认以数字序列化，这里统一转成字符串保存。
class AuthUser {
  const AuthUser({
    required this.id,
    required this.account,
    required this.nickname,
    this.avatarUrl,
    required this.role,
    required this.status,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as String? ?? '',
        account: json['account'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        avatarUrl: json['avatarUrl'] as String?,
        role: '${json['role'] ?? ''}',
        status: '${json['status'] ?? ''}',
      );

  final String id;
  final String account;
  final String nickname;
  final String? avatarUrl;
  final String role;
  final String status;

  Map<String, dynamic> toJson() => {
        'id': id,
        'account': account,
        'nickname': nickname,
        'avatarUrl': avatarUrl,
        'role': role,
        'status': status,
      };
}

/// 管理平台认证服务：登录、恢复会话、退出登录。
///
/// 对接管理平台 AuthEndpoints：
/// - POST {baseUrl}/api/auth/login  body: {"account":..., "password":...}
/// - 成功响应：{"accessToken":..., "expiresInSeconds":..., "user":{...}}
/// - 失败响应：{"error": "..."}（401/400 等）
class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  static const _tag = 'Auth';

  static const _keyBaseUrl = 'auth-base-url';
  static const _keyToken = 'auth-access-token';
  static const _keyUser = 'auth-user';
  static const _keyAccount = 'auth-account';

  String? _baseUrl;
  String? _accessToken;
  AuthUser? _user;
  String? _lastAccount;

  /// HTTP 客户端，生产环境使用默认实现（懒加载），测试可通过 [debugHttpClient] 注入。
  http.Client? _client;

  http.Client get _httpClient => _client ??= http.Client();

  /// 测试专用：注入 MockClient 以模拟管理平台响应。
  @visibleForTesting
  set debugHttpClient(http.Client client) => _client = client;

  /// 测试专用：清空单例内存状态并恢复默认 HTTP 客户端。
  @visibleForTesting
  void resetForTesting() {
    _baseUrl = null;
    _accessToken = null;
    _user = null;
    _lastAccount = null;
    _client = null;
  }

  /// 管理平台基础地址（已规范化，无末尾斜杠）。
  String? get baseUrl => _baseUrl;

  /// 登录后获得的 JWT，访问需鉴权接口时放入 Authorization: Bearer 头。
  String? get accessToken => _accessToken;

  AuthUser? get user => _user;

  /// 上次成功登录使用的账号（用于回填）。
  String? get lastAccount => _lastAccount;

  bool get isLoggedIn => _accessToken != null && _accessToken!.isNotEmpty;

  /// 从本地存储恢复登录状态（应用启动时调用一次）。
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_keyBaseUrl);
    _accessToken = prefs.getString(_keyToken);
    _lastAccount = prefs.getString(_keyAccount);
    final userJson = prefs.getString(_keyUser);
    if (userJson != null && userJson.isNotEmpty) {
      try {
        _user = AuthUser.fromJson(jsonDecode(userJson) as Map<String, dynamic>);
      } catch (_) {
        _user = null;
      }
    }
    log.LoggerService.info(
      '恢复会话  baseUrl=${_baseUrl ?? '<未设置>'}  account=$_lastAccount  loggedIn=$isLoggedIn',
      name: _tag,
    );
  }

  /// 调用管理平台登录接口。成功后保存会话，失败抛出 [AuthException]。
  Future<AuthUser> login({
    required String baseUrl,
    required String account,
    required String password,
  }) async {
    final sw = Stopwatch()..start();
    final url = normalizeBaseUrl(baseUrl);
    if (url == null) {
      log.LoggerService.warning('登录失败：URL 格式非法  rawUrl=$baseUrl', name: _tag);
      throw AuthException('请输入正确的管理平台 URL');
    }

    log.LoggerService.info('登录请求 POST $url/api/auth/login  account=$account', name: _tag);
    final http.Response resp;
    try {
      resp = await _httpClient
          .post(
            Uri.parse('$url/api/auth/login'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({'account': account, 'password': password}),
          )
          .timeout(const Duration(seconds: 15));
    } catch (e, st) {
      sw.stop();
      final isTimeout =
          e.toString().toLowerCase().contains('timeout') ||
          e is TimeoutException ||
          sw.elapsedMilliseconds >= 15000 - 200;
      log.LoggerService.error(
        '登录${isTimeout ? '超时' : '失败（网络）'} elapsed=${sw.elapsedMilliseconds}ms  url=$url  err=${e.runtimeType}: $e',
        name: _tag,
        error: e,
        stackTrace: st,
      );
      throw AuthException(
        isTimeout
            ? '管理平台登录超时（${sw.elapsedMilliseconds}ms），请确认地址 $url 是否可访问且已部署'
            : '无法连接管理平台，请检查 URL 或网络后重试',
      );
    }

    sw.stop();
    Map<String, dynamic>? body;
    if (resp.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {
        // 非 JSON 响应，按状态码处理
      }
    }

    if (resp.statusCode != 200) {
      final msg = body?['error'] as String?;
      final finalMsg = msg ?? '登录失败（HTTP ${resp.statusCode}）';
      log.LoggerService.warning(
        '登录失败 HTTP ${resp.statusCode}  elapsed=${sw.elapsedMilliseconds}ms  msg=$finalMsg',
        name: _tag,
      );
      throw AuthException(finalMsg);
    }

    final token = body?['accessToken'] as String?;
    final userJson = body?['user'];
    if (token == null || token.isEmpty || userJson is! Map<String, dynamic>) {
      log.LoggerService.warning('登录响应格式异常（缺 token 或 user 字段）', name: _tag);
      throw AuthException('登录响应格式异常');
    }
    final user = AuthUser.fromJson(userJson);

    _baseUrl = url;
    _accessToken = token;
    _user = user;
    _lastAccount = account;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBaseUrl, url);
    await prefs.setString(_keyToken, token);
    await prefs.setString(_keyUser, jsonEncode(user.toJson()));
    await prefs.setString(_keyAccount, account);

    log.LoggerService.info(
      '登录成功  elapsed=${sw.elapsedMilliseconds}ms  uid=${user.id}  nickname=${user.nickname}  role=${user.role}',
      name: _tag,
    );
    return user;
  }

  /// 单独保存管理平台地址（登录页"配置"入口），不影响登录状态。
  /// 地址非法时抛出 [AuthException]。
  Future<String> saveBaseUrl(String raw) async {
    final url = normalizeBaseUrl(raw);
    if (url == null) {
      log.LoggerService.warning('保存管理平台地址失败（格式非法） raw="$raw"', name: _tag);
      throw AuthException('请输入正确的管理平台 URL');
    }
    _baseUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyBaseUrl, url);
    log.LoggerService.info('保存管理平台地址 url=$url', name: _tag);
    return url;
  }

  /// 退出登录：仅清除 token 与用户信息，保留管理平台地址与账号用于下次回填。
  Future<void> logout() async {
    final uid = _user?.id;
    _accessToken = null;
    _user = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyToken);
    await prefs.remove(_keyUser);
    log.LoggerService.info('用户登出  uid=$uid  account=$_lastAccount', name: _tag);
  }

  /// 规范化管理平台地址：补全 scheme、去除末尾斜杠；非法地址返回 null。
  static String? normalizeBaseUrl(String raw) {
    var input = raw.trim();
    if (input.isEmpty) return null;
    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      input = 'http://$input';
    }
    final uri = Uri.tryParse(input);
    if (uri == null || uri.host.isEmpty) return null;
    return input.endsWith('/') ? input.substring(0, input.length - 1) : input;
  }
}
