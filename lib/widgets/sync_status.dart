import 'package:material_ui/material_ui.dart';

import '../services/sync.dart';

/// 読み込み中のバー、エラー、ダミー表示中の案内をまとめて表示する
class SyncStatus extends StatelessWidget {
  const SyncStatus({super.key, required this.loading, this.error, this.dummyMessage});

  final bool loading;
  final String? error;

  /// ダミーデータ表示中に出す案内（null なら出さない）
  final String? dummyMessage;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (loading) const LinearProgressIndicator(),
        if (dummyMessage != null)
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(12),
            child: Text(dummyMessage!, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (error != null)
          MaterialBanner(
            content: Text(error!),
            actions: [
              TextButton(onPressed: () => syncAll(prompt: true), child: const Text('再試行')),
            ],
          ),
      ],
    );
  }
}
