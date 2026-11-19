import '../util/date_text.dart';

/// 受信時刻の表示：今日なら「10:05」、今年なら「11/3」、それ以前は「2025/11/3」
String formatReceived(DateTime t) {
  final now = DateTime.now();
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return hhmm(t);
  }
  if (t.year == now.year) return '${t.month}/${t.day}';
  return '${t.year}/${t.month}/${t.day}';
}

/// 本文画面などで使う詳しい日時
String formatFull(DateTime t) {
  return '${t.year}/${t.month}/${t.day} ${hhmm(t)}';
}
