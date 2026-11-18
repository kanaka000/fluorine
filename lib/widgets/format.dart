/// 受信時刻の表示：今日なら「10:05」、今年なら「11/3」、それ以前は「2025/11/3」
String formatReceived(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return '${two(t.hour)}:${two(t.minute)}';
  }
  if (t.year == now.year) return '${t.month}/${t.day}';
  return '${t.year}/${t.month}/${t.day}';
}

/// 本文画面などで使う詳しい日時
String formatFull(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}/${t.month}/${t.day} ${two(t.hour)}:${two(t.minute)}';
}
