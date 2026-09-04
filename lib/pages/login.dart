import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:livekit_example/pages/meeting_workbench.dart';
import 'package:livekit_example/services/auth_service.dart';
import 'package:livekit_example/theme.dart';
import 'package:livekit_example/widgets/text_field.dart';

/// 管理平台登录页：填写用户名、密码后调用 /api/auth/login。管理平台地址在设置中配置。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _accountCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  bool _busy = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 回填上次成功登录使用的账号
    _accountCtrl.text = AuthService.instance.lastAccount ?? '';
  }

  @override
  void dispose() {
    _accountCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (_busy) return;

    final url = AuthService.instance.baseUrl ?? '';
    final account = _accountCtrl.text.trim();
    final password = _passwordCtrl.text;

    if (url.isEmpty) {
      setState(() => _error = '请先在设置中配置管理平台地址');
      return;
    }
    if (account.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写用户名和密码');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await AuthService.instance.login(
        baseUrl: url,
        account: account,
        password: password,
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(builder: (_) => const MeetingWorkbenchPage()),
      );
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '登录失败：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _showConfigDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ServerUrlConfigDialog(
        initialUrl: AuthService.instance.baseUrl ?? '',
        onSaved: (_) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('管理平台地址已保存')),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          actions: [
            IconButton(
              tooltip: '配置管理平台地址',
              icon: const Icon(Icons.settings),
              onPressed: _busy ? null : _showConfigDialog,
            ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SvgPicture.asset('images/logo-dark.svg', width: 180),
                    const SizedBox(height: 16),
                    Text(
                      '登录管理平台',
                      style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '请使用管理平台账号登录',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: LKColors.textSecondary),
                    ),
                    const SizedBox(height: 28),
                    _buildLoginCard(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _buildLoginCard(BuildContext context) => Container(
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
              label: '用户名',
              ctrl: _accountCtrl,
              icon: Icons.person,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
            ),
            const SizedBox(height: 18),
            LKTextField(
              label: '密码',
              ctrl: _passwordCtrl,
              icon: Icons.lock,
              obscureText: _obscurePassword,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _login(),
              suffixIcon: IconButton(
                tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                icon: Icon(
                  _obscurePassword ? Icons.visibility_off : Icons.visibility,
                  size: 18,
                  color: LKColors.textSecondary,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.error_outline,
                      size: 16, color: LKColors.destructiveDark),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: LKColors.destructiveDark,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _busy ? null : _login,
              icon: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.login),
              label: Text(_busy ? '登录中...' : '登录'),
            ),
          ],
        ),
      );
}

/// 管理平台地址配置对话框：保存到本地，下次启动自动回填，无需每次登录填写。
class _ServerUrlConfigDialog extends StatefulWidget {
  const _ServerUrlConfigDialog({
    required this.initialUrl,
    required this.onSaved,
  });

  final String initialUrl;
  final ValueChanged<String> onSaved;

  @override
  State<_ServerUrlConfigDialog> createState() => _ServerUrlConfigDialogState();
}

class _ServerUrlConfigDialogState extends State<_ServerUrlConfigDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialUrl);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = AuthService.normalizeBaseUrl(_controller.text);
    if (url == null) {
      setState(() => _error = '请输入正确的管理平台 URL，如 http://192.168.1.10:5000');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await AuthService.instance.saveBaseUrl(url);
      if (!mounted) return;
      widget.onSaved(saved);
      Navigator.of(context).pop();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('配置管理平台地址'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '地址将保存在本地，之后登录无需重复填写。',
              style: TextStyle(fontSize: 13, color: LKColors.textSecondary),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.link, size: 18),
                hintText: 'http://<服务器地址>:<端口>',
              ),
              onSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(
                  color: LKColors.destructiveDark,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Text('保存'),
          ),
        ],
      );
}
