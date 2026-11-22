import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../widgets/confirm_dialog.dart';
import 'package:flutter/services.dart';

import '../data/mail_store.dart';
import '../data/models.dart';
import '../widgets/timed_snack.dart';
import 'errors.dart';

/// 添付ファイルを外部アプリで開く（2026-11-19）
/// - 開けるのは決めた拡張子だけ（許可リスト）。Gmailの種類（MIME）が拡張子と食い違うものは開かない
/// - ダウンロードしたあと、中身の先頭も確かめる（「請求書.pdf」なのに中身が別物、を防ぐ）
/// - アプリ専用の一時フォルダ（cache/attachments）に置き、Android側（MainActivity）が
///   読み取り許可付きで外部アプリに渡す。ストレージの権限は使わない
/// - 一時ファイルは起動のたびに1日より古いものを消す

const _channel = MethodChannel('app/attachments');

/// これより大きい添付は、読み込む前に確認する
const largeAttachmentBytes = 25 * 1024 * 1024;

class _Kind {
  const _Kind(this.mime, {this.aliases = const [], this.check});

  /// 外部アプリに渡す種類
  final String mime;

  /// Gmailの種類がこれでもよい（送る側のソフトによって違うことがあるもの）
  final List<String> aliases;

  /// 中身の先頭の確かめ方（null なら確かめない）
  final bool Function(List<int> head)? check;
}

bool _startsWith(List<int> b, List<int> sig, [int offset = 0]) {
  if (b.length < offset + sig.length) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[offset + i] != sig[i]) return false;
  }
  return true;
}

bool _isPdf(List<int> b) {
  // %PDF- は先頭から1024バイト以内にあればよい（PDFの決まり）
  final n = b.length < 1024 ? b.length : 1024;
  for (var i = 0; i + 5 <= n; i++) {
    if (_startsWith(b, const [0x25, 0x50, 0x44, 0x46, 0x2D], i)) return true;
  }
  return false;
}

bool _isJpeg(List<int> b) => _startsWith(b, const [0xFF, 0xD8, 0xFF]);
bool _isPng(List<int> b) => _startsWith(b, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
bool _isGif(List<int> b) => _startsWith(b, 'GIF8'.codeUnits);
bool _isWebp(List<int> b) => _startsWith(b, 'RIFF'.codeUnits) && _startsWith(b, 'WEBP'.codeUnits, 8);
bool _isHeic(List<int> b) => _startsWith(b, 'ftyp'.codeUnits, 4);
// Word・Excel・PowerPoint の古い形式（97-2003）
bool _isOle(List<int> b) => _startsWith(b, const [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]);
// docx・xlsx・pptx は中身が zip
bool _isZip(List<int> b) => _startsWith(b, const [0x50, 0x4B, 0x03, 0x04]);
// 文字のファイルに 0 のバイトは入らない
bool _isText(List<int> b) => !b.contains(0);

const _office = 'application/vnd.openxmlformats-officedocument';

/// 開ける拡張子（ユーザー決定 2026-11-19：よく使う書類と画像）
const Map<String, _Kind> _allowed = {
  'pdf': _Kind('application/pdf', aliases: ['application/x-pdf', 'application/acrobat'], check: _isPdf),
  'jpg': _Kind('image/jpeg', aliases: ['image/jpg', 'image/pjpeg'], check: _isJpeg),
  'jpeg': _Kind('image/jpeg', aliases: ['image/jpg', 'image/pjpeg'], check: _isJpeg),
  'png': _Kind('image/png', check: _isPng),
  'gif': _Kind('image/gif', check: _isGif),
  'webp': _Kind('image/webp', check: _isWebp),
  'heic': _Kind('image/heic', aliases: ['image/heif', 'image/heic-sequence', 'image/heif-sequence'], check: _isHeic),
  'doc': _Kind('application/msword', check: _isOle),
  'xls': _Kind('application/vnd.ms-excel', check: _isOle),
  'ppt': _Kind('application/vnd.ms-powerpoint', aliases: ['application/mspowerpoint'], check: _isOle),
  'docx': _Kind('$_office.wordprocessingml.document', aliases: ['application/zip'], check: _isZip),
  'xlsx': _Kind('$_office.spreadsheetml.sheet', aliases: ['application/zip'], check: _isZip),
  'pptx': _Kind('$_office.presentationml.presentation', aliases: ['application/zip'], check: _isZip),
  'txt': _Kind('text/plain', check: _isText),
  'csv': _Kind('text/csv',
      aliases: ['text/comma-separated-values', 'application/csv', 'text/x-csv', 'application/vnd.ms-excel', 'text/plain'],
      check: _isText),
};

/// 送る側が種類を付けなかったときの、意味のない種類（拡張子で判断する）
const _generic = {
  '',
  'application/octet-stream',
  'binary/octet-stream',
  'application/x-download',
  'application/force-download',
  'application/download',
  'application/unknown',
};

/// 文字の向きを変える見えない文字（「請求書［U+202E］fdp.exe」のような見せかけに使われる）
final _bidi = RegExp('[\u200E\u200F\u202A-\u202E\u2066-\u2069]');

/// 画面に出すファイル名（見えない制御文字を外す）
String attachmentDisplayName(String filename) =>
    filename.replaceAll(_bidi, '').replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').trim();

/// 拡張子（小文字。なければ空）
String attachmentExtension(String filename) {
  final name = attachmentDisplayName(filename);
  final base = name.split(RegExp(r'[/\\]')).last;
  final dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).trim().toLowerCase();
}

enum AttachmentCheck { ok, notAllowed, mismatch }

/// 開いてよい添付か（ダウンロードする前の判定）
AttachmentCheck checkAttachment(MailAttachment a) {
  final kind = _allowed[attachmentExtension(a.filename)];
  if (kind == null) return AttachmentCheck.notAllowed;
  final mime = a.mimeType.split(';').first.trim().toLowerCase();
  if (_generic.contains(mime) || mime == kind.mime || kind.aliases.contains(mime)) {
    return AttachmentCheck.ok;
  }
  return AttachmentCheck.mismatch;
}

/// 一時フォルダに置くときのファイル名（フォルダの区切り・制御文字・使えない文字を外す）
String safeAttachmentFileName(String filename) {
  final ext = attachmentExtension(filename);
  var base = attachmentDisplayName(filename).split(RegExp(r'[/\\]')).last;
  if (ext.isNotEmpty) base = base.substring(0, base.length - ext.length - 1);
  var stem = base
      .replaceAll(RegExp(r'[<>:"|?*\x00-\x1F\x7F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  if (stem.length > 80) stem = stem.substring(0, 80).trim();
  if (stem.isEmpty) stem = 'attachment';
  return ext.isEmpty ? stem : '$stem.$ext';
}

const _notAllowedMessage = '安全のため、この種類のファイルは開けません。パソコンのGmailで開いてください';
const _mismatchMessage = 'ファイル名と中身の種類が食い違っているため、安全のため開けません。パソコンのGmailで確かめてください';

/// 添付をタップしたとき
Future<void> openAttachment(BuildContext context, Mail mail, MailAttachment a) async {
  final messenger = ScaffoldMessenger.of(context);
  void notice(String m) => showTimedSnackOn(messenger, m);

  switch (checkAttachment(a)) {
    case AttachmentCheck.notAllowed:
      notice(_notAllowedMessage);
      return;
    case AttachmentCheck.mismatch:
      notice(_mismatchMessage);
      return;
    case AttachmentCheck.ok:
      break;
  }
  final kind = _allowed[attachmentExtension(a.filename)]!;
  final name = attachmentDisplayName(a.filename);

  // 大きいファイルは読み込む前に確認する
  if (a.size > largeAttachmentBytes) {
    final ok = await askConfirm(context, title: '大きいファイルです', message: '「$name」は ${a.sizeText} あります。読み込んで開きますか？\n'
            'モバイル回線では通信量にご注意ください。', okLabel: '開く');
    if (!ok || !context.mounted) return;
  }

  // 読み込み中の表示（閉じられないダイアログ）
  final nav = Navigator.of(context, rootNavigator: true);
  var progressShown = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            const SizedBox(width: 16),
            Expanded(child: Text('「$name」を読み込んでいます…')),
          ],
        ),
      ),
    ),
  );
  void closeProgress() {
    if (progressShown) {
      progressShown = false;
      nav.pop();
    }
  }

  try {
    final bytes = await mailStore.downloadAttachment(mail, a);
    // 中身の先頭を確かめる
    final head = bytes.length > 8192 ? bytes.sublist(0, 8192) : bytes;
    if (kind.check != null && !kind.check!(head)) {
      closeProgress();
      notice(_mismatchMessage);
      return;
    }
    final dir = await _channel.invokeMethod<String>('dir');
    if (dir == null) throw const AppMessage('一時フォルダを用意できませんでした');
    // 同じ名前の添付がぶつからないよう、開くたびに小さなフォルダを作る
    final folder = Directory('$dir/${DateTime.now().microsecondsSinceEpoch}');
    await folder.create(recursive: true);
    final file = File('${folder.path}/${safeAttachmentFileName(a.filename)}');
    await file.writeAsBytes(bytes, flush: true);
    closeProgress();
    final res = await _channel.invokeMethod<String>('open', {'path': file.path, 'mime': kind.mime});
    if (res == 'noApp') notice('このファイルを開けるアプリが見つかりません');
  } catch (e) {
    closeProgress();
    notice('開けませんでした：${friendlyError(e)}');
  }
}

/// 起動時に、1日より古い一時ファイルを消す
Future<void> cleanupAttachmentCache() async {
  try {
    final dir = await _channel.invokeMethod<String>('dir');
    if (dir == null) return;
    final limit = DateTime.now().subtract(const Duration(days: 1));
    await for (final e in Directory(dir).list()) {
      try {
        if ((await e.stat()).modified.isBefore(limit)) await e.delete(recursive: true);
      } catch (err) {
        devLog('一時ファイルの削除エラー: $err');
      }
    }
  } catch (e) {
    devLog('一時ファイルの片付けエラー: $e');
  }
}
