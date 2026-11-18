import '../data/calendar_store.dart';
import '../data/mail_store.dart';
import '../data/task_store.dart';

/// メール・カレンダー・タスクをまとめて読み込む。
/// prompt=true はボタン操作のときだけ（まだ許可していない権限の許可画面を出す）
Future<void> syncAll({bool prompt = false}) async {
  await mailStore.reload(prompt: prompt); // 許可画面はここで1回だけ出る
  await Future.wait([calendarStore.reload(), taskStore.reload()]);
}

/// ログアウト時：すべて空にする
void resetAll() {
  mailStore.resetForSignOut();
  calendarStore.resetForSignOut();
  taskStore.resetForSignOut();
}

/// 自動読み込みがオフで起動したとき：手動で読み込むまで空にする
void clearAllForManual() {
  mailStore.clearForManual();
  calendarStore.clearForManual();
  taskStore.clearForManual();
}
