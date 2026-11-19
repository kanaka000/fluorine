// 日付・時刻を文字にする小さな部品（2026-11-19 の整理で、各ファイルにあった曜日の表などをまとめた）

const weekdayNames = ['月', '火', '水', '木', '金', '土', '日'];

/// 曜日の1文字（月〜日）
String weekdayJa(DateTime d) => weekdayNames[d.weekday - 1];

/// 2けたにそろえる（5 → 05）
String pad2(int v) => v.toString().padLeft(2, '0');

/// 時刻「09:05」
String hhmm(DateTime d) => '${pad2(d.hour)}:${pad2(d.minute)}';
