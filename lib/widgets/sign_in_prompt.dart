import 'package:flutter/material.dart';

import '../services/google_auth.dart';
import '../services/sync.dart';
import '../services/errors.dart';

/// Googleにログインして、メール・カレンダー・タスクを読み込む（ログインボタン用）
Future<void> signInAndSync(BuildContext context) async {
  try {
    await googleAuth.signIn();
    await syncAll(prompt: true); // 初回はアクセス許可画面が出る
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('ログインできませんでした：${friendlyError(e)}')));
    }
  }
}

/// ログアウト中に、一覧の代わりに出すログインの案内（2026-11-16 追加。ダミーデータの代わり）
/// 親の画面が googleAuth の変化を見ている前提（ログインの準備ができるとボタンが押せるようになる）
class SignInPrompt extends StatelessWidget {
  const SignInPrompt({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.login),
              label: const Text('Googleでログイン'),
              onPressed: googleAuth.initialized ? () => signInAndSync(context) : null,
            ),
            if (!googleConfigured) ...[
              const SizedBox(height: 16),
              Text(
                const GoogleNotConfigured().message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
