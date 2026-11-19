import 'claude_service.dart';

/// ✨の「メールを探して」から Gmail の検索文を作る（2026-11-19）

/// 検索の言葉から、Gmailの検索で特別な意味を持つ記号を外す。空白を含むなら "…" で囲む
String _term(String s) {
  var t = s
      .replaceAll(RegExp(r'["(){}\[\]]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'^-+'), '')
      .trim();
  if (t.isEmpty) return '';
  // OR・AND は検索の決まり文句なので、言葉だけのときは囲んで普通の文字にする
  if (t.contains(' ') || t == 'OR' || t == 'AND') t = '"$t"';
  return t;
}

String _ymd(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

const _fileTypeQuery = {
  'pdf': 'filename:pdf',
  'image': '(filename:jpg OR filename:jpeg OR filename:png OR filename:gif OR filename:heic OR filename:webp)',
  'word': '(filename:doc OR filename:docx)',
  'excel': '(filename:xls OR filename:xlsx OR filename:csv)',
  'powerpoint': '(filename:ppt OR filename:pptx)',
};

const fileTypeNames = {
  'pdf': 'PDF',
  'image': '写真・画像',
  'word': 'Word',
  'excel': 'Excel・CSV',
  'powerpoint': 'PowerPoint',
};

/// Gmailの検索文。手がかりが1つもなければ空
String buildMailQuery(AiMailSearch s) {
  final parts = <String>[];
  final k = _term(s.keyword ?? '');
  // 言葉は件名・本文と、添付ファイルの名前の両方で探す
  if (k.isNotEmpty) parts.add('($k OR filename:$k)');
  final from = _term(s.sender ?? '');
  if (from.isNotEmpty) parts.add('from:$from');
  final type = _fileTypeQuery[s.fileType];
  if (s.hasAttachment || type != null) parts.add('has:attachment');
  if (type != null) parts.add(type);
  if (s.dateFrom != null) parts.add('after:${_ymd(s.dateFrom!)}');
  // before はその日を含まないので、1日足す
  if (s.dateTo != null) parts.add('before:${_ymd(s.dateTo!.add(const Duration(days: 1)))}');
  return parts.join(' ');
}

/// 画面に出す検索条件（「言葉「見積」・差出人「田中」・添付あり（PDF）・10/1〜10/31」）
String describeMailSearch(AiMailSearch s) {
  final parts = <String>[];
  final k = (s.keyword ?? '').trim();
  if (k.isNotEmpty) parts.add('言葉「$k」');
  final from = (s.sender ?? '').trim();
  if (from.isNotEmpty) parts.add('差出人「$from」');
  final type = fileTypeNames[s.fileType];
  if (type != null) {
    parts.add('添付あり（$type）');
  } else if (s.hasAttachment) {
    parts.add('添付あり');
  }
  String md(DateTime d) => '${d.year}/${d.month}/${d.day}';
  if (s.dateFrom != null || s.dateTo != null) {
    parts.add('${s.dateFrom != null ? md(s.dateFrom!) : ''}〜${s.dateTo != null ? md(s.dateTo!) : ''}');
  }
  return parts.join('・');
}
