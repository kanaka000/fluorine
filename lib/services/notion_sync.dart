import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_settings.dart';
import '../data/memo_store.dart';
import 'errors.dart';

/// Notionのトークンと保存先のページは secrets.json から読み込む（コードには書かない）
/// - NOTION_TOKEN：Notionの接続（インテグレーション）のトークン
/// - NOTION_PAGE_ID：「Fluorine Memo」ページのID（ページのURLをそのまま入れてもよい）
const notionToken = String.fromEnvironment('NOTION_TOKEN');
const _notionPageSetting = String.fromEnvironment('NOTION_PAGE_ID');

const _notionVersion = '2026-03-11';

final notionSync = NotionSync();

/// メモをNotionに送る（アプリ→Notionの一方向。2026-11-17）
/// - 「Fluorine Memo」ページの下に、メモ1つにつき1つのサブページを作る
/// - 保存のたびに自動で送る。失敗した分は覚えておき、次に開いたとき（または「今すぐ送る」）に送り直す
/// - アプリで削除したらNotionでもゴミ箱へ。「元に戻す」でNotionからも戻す
/// - メモの色はページのアイコン（色の絵文字）で表す
class NotionSync extends ChangeNotifier {
  /// メモのID → NotionのページID
  final Map<String, String> _pageIds = {};

  /// 送る必要がある（追加・変更した）メモのID
  final Set<String> _dirty = {};

  /// Notionでゴミ箱に入れる必要がある（アプリで削除した）メモのID
  final Set<String> _trash = {};

  SharedPreferences? _prefs;
  Timer? _timer;
  bool _again = false;

  bool syncing = false;
  String? lastError;

  /// Notionから復元している最中か（2026-11-18）。restoreDone／restoreTotal は進み具合
  bool restoring = false;
  int restoreDone = 0;
  int restoreTotal = 0;
  DateTime? lastSyncedAt;

  /// 保存先のページID（URLから取り出す。入っていなければ null）
  static String? get parentId {
    final s = _notionPageSetting.replaceAll('-', '');
    final all = RegExp(r'[0-9a-fA-F]{32}').allMatches(s).toList();
    return all.isEmpty ? null : all.last.group(0);
  }

  /// secrets.json にトークンとページIDが入っているか
  bool get configured => _tokenSet && parentId != null;

  /// 空白・見本のまま（「ここに」を含む）のトークンは未設定として扱う（2026-11-18 C01）
  static bool get _tokenSet => notionToken.trim().isNotEmpty && !notionToken.contains('ここに');

  /// 連携がオンで、使える状態か
  bool get active => configured && appSettings.notionSync;

  /// まだ送れていない件数
  int get pendingCount => _dirty.length + _trash.length;

  /// 「Notionから復元」を押せるか（アプリにメモが1件もないときだけ。2026-11-18 ユーザー決定）
  bool get canRestore => configured && memoStore.memos.isEmpty && !syncing && !restoring;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    try {
      final ids = p.getString('notion_page_ids');
      if (ids != null) _pageIds.addAll((jsonDecode(ids) as Map).cast<String, String>());
      _dirty.addAll(p.getStringList('notion_dirty') ?? const []);
      _trash.addAll(p.getStringList('notion_trash') ?? const []);
      final t = p.getString('notion_last_synced');
      lastSyncedAt = t == null ? null : DateTime.tryParse(t);
    } catch (e) {
      devLog('Notion連携の状態の読み込みに失敗: $e');
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    _prefs = p;
    await p.setString('notion_page_ids', jsonEncode(_pageIds));
    await p.setStringList('notion_dirty', _dirty.toList());
    await p.setStringList('notion_trash', _trash.toList());
    if (lastSyncedAt != null) await p.setString('notion_last_synced', lastSyncedAt!.toIso8601String());
  }

  /// 連携のオン／オフ（メモの設定から）。オンにしたときは、今あるメモをすべて送る
  /// 復元の直後にオンにするときは sendAll: false（復元したメモは同じページにつながっているので送り直さない）
  Future<void> setEnabled(bool v, {bool sendAll = true}) async {
    appSettings.setNotionSync(v);
    if (!v) _timer?.cancel(); // 待っている送信も止める（2026-11-18 B07）
    if (v && sendAll) {
      _dirty.addAll(memoStore.memos.map((m) => m.id));
      await _persist();
      unawaited(flush());
    }
    notifyListeners();
  }

  /// 「端末内のデータを消す」のあと：送信待ち・ページの対応・状態を空にする（Notionのページはそのまま）
  void clearLocal() {
    _timer?.cancel();
    _pageIds.clear();
    _dirty.clear();
    _trash.clear();
    lastError = null;
    lastSyncedAt = null;
    notifyListeners();
  }

  /// メモを追加・変更したとき（MemoStore から呼ばれる）
  void memoSaved(Memo m) {
    if (!appSettings.notionSync) return;
    _trash.remove(m.id);
    _dirty.add(m.id);
    _persist();
    _schedule();
  }

  /// メモを削除したとき（MemoStore から呼ばれる）
  void memoRemoved(Memo m) {
    if (!appSettings.notionSync) return;
    _dirty.remove(m.id);
    if (_pageIds.containsKey(m.id)) _trash.add(m.id);
    _persist();
    _schedule();
  }

  /// 続けて保存したときに1回にまとめるため、少し待ってから送る
  void _schedule() {
    notifyListeners();
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), flush);
  }

  /// たまっている分をNotionに送る
  Future<void> flush() async {
    if (!active) return;
    if (syncing) {
      _again = true;
      return;
    }
    if (pendingCount == 0) return;
    syncing = true;
    lastError = null;
    notifyListeners();
    try {
      for (final id in [..._trash]) {
        if (!active) break; // 連携をオフにしたら、残りは送らない（2026-11-18 B07）
        final pid = _pageIds[id];
        if (pid != null) {
          try {
            await _request('PATCH', '/v1/pages/$pid', {'in_trash': true});
          } on _NotFound {
            // Notion側で既に消されている
          }
        }
        _trash.remove(id);
        await _persist();
      }
      for (final id in [..._dirty]) {
        if (!active) break; // 連携をオフにしたら、残りは送らない（2026-11-18 B07）
        final m = memoStore.find(id);
        if (m != null) await _upsert(m);
        _dirty.remove(id);
        await _persist();
      }
      lastSyncedAt = DateTime.now();
      await _persist();
    } catch (e) {
      lastError = friendlyError(e);
      devLog('Notionへの送信に失敗: $e');
    }
    syncing = false;
    notifyListeners();
    if (_again) {
      _again = false;
      if (lastError == null && pendingCount > 0) unawaited(flush());
    }
  }

  /// メモ1件をNotionのページにする（なければ作る、あれば書き換える）
  Future<void> _upsert(Memo m) async {
    final title = m.title.trim().isEmpty ? '無題' : m.title.trim();
    final props = {
      'title': {
        'title': [
          {
            'text': {'content': title.length > 1900 ? title.substring(0, 1900) : title},
          },
        ],
      },
    };
    final icon = {'type': 'emoji', 'emoji': _iconOf(m.colorKey)};
    final md = toNotionMarkdown(m.body);

    final pid = _pageIds[m.id];
    if (pid != null) {
      try {
        // ゴミ箱から戻す（「元に戻す」のとき）＋タイトル・アイコン
        await _request('PATCH', '/v1/pages/$pid', {'in_trash': false, 'properties': props, 'icon': icon});
        await _request('PATCH', '/v1/pages/$pid/markdown', {
          'markdown_version': 'v2',
          'type': 'replace_content',
          'replace_content': {'new_str': md},
        });
        return;
      } on _NotFound {
        // Notionでページが完全に消された → 作り直す
        _pageIds.remove(m.id);
      }
    }
    final Map<String, dynamic> res;
    try {
      res = await _request('POST', '/v1/pages', {
        'parent': {'type': 'page_id', 'page_id': parentId},
        'icon': icon,
        'properties': props,
        if (md.trim().isNotEmpty) ...{'markdown': md, 'markdown_version': 'v2'},
      });
    } on _NotFound {
      throw NotionException('保存先のページが見つかりません。NOTION_PAGE_ID と、'
          'Notionでそのページの「接続」に、作った接続（インテグレーション）を追加したかを確かめてください');
    }
    _pageIds[m.id] = res['id'] as String;
    await _persist();
  }

  // ---------------- Notionから復元（2026-11-18） ----------------
  // アプリを入れ直してメモが空になったとき用の手動の取り込み。普段は今までどおりアプリ→Notionの一方向

  /// 保存先ページの下にあるページ（ゴミ箱・削除待ちを除く）の一覧
  Future<List<NotionPageRef>> listRestorablePages() async {
    restoring = true;
    notifyListeners();
    try {
      final pages = <NotionPageRef>[];
      String? cursor;
      do {
        final Map<String, dynamic> res;
        try {
          res = await _request('GET', '/v1/blocks/$parentId/children', null, {
            'page_size': '100',
            'start_cursor': ?cursor,
          });
        } on _NotFound {
          throw NotionException('保存先のページが見つかりません。NOTION_PAGE_ID と、'
              'Notionでそのページの「接続」に、作った接続（インテグレーション）を追加したかを確かめてください');
        }
        for (final b in (res['results'] as List? ?? const [])) {
          if (b is! Map || b['type'] != 'child_page') continue;
          if (b['in_trash'] == true || b['archived'] == true) continue;
          final title = (b['child_page'] as Map?)?['title'] as String? ?? '';
          pages.add(NotionPageRef(b['id'] as String, title));
        }
        cursor = res['has_more'] == true ? res['next_cursor'] as String? : null;
      } while (cursor != null);
      // アプリで削除して、まだNotionのゴミ箱に入れていないページは戻さない
      final trashing = _trash.map((id) => _pageIds[id]).whereType<String>().map(_norm).toSet();
      return pages.where((p) => !trashing.contains(_norm(p.id))).toList();
    } finally {
      restoring = false;
      notifyListeners();
    }
  }

  /// ページをメモとして取り込む。途中で失敗したら1件も取り込まない（やり直せるように）。
  /// 取り込んだメモとページの対応表も作るので、以後の保存は同じページを更新する
  Future<int> restore(List<NotionPageRef> pages) async {
    restoring = true;
    restoreDone = 0;
    restoreTotal = pages.length;
    notifyListeners();
    try {
      final memos = <Memo>[];
      final ids = <String, String>{};
      var seq = DateTime.now().microsecondsSinceEpoch;
      for (final p in pages) {
        Map<String, dynamic>? page;
        try {
          page = await _request('GET', '/v1/pages/${p.id}');
        } on _NotFound {
          page = null; // 読み込みの途中で消された
        }
        if (page != null && page['in_trash'] != true && page['archived'] != true) {
          final md = await _request('GET', '/v1/pages/${p.id}/markdown', null, {'markdown_version': 'v2'});
          final icon = page['icon'];
          final created = DateTime.tryParse(page['created_time'] as String? ?? '')?.toLocal() ?? DateTime.now();
          final updated = DateTime.tryParse(page['last_edited_time'] as String? ?? '')?.toLocal() ?? created;
          final m = Memo(
            id: '${seq++}',
            title: p.title,
            body: fromNotionMarkdown(md['markdown'] as String? ?? ''),
            createdAt: created,
            updatedAt: updated,
            colorKey: icon is Map && icon['type'] == 'emoji' ? _colorOf(icon['emoji'] as String?) : null,
          );
          memos.add(m);
          ids[m.id] = page['id'] as String? ?? p.id;
        }
        restoreDone++;
        notifyListeners();
      }
      if (memos.isNotEmpty) await memoStore.addRestored(memos);
      _pageIds.addAll(ids);
      await _persist();
      return memos.length;
    } finally {
      restoring = false;
      notifyListeners();
    }
  }

  static String _norm(String id) => id.replaceAll('-', '').toLowerCase();

  /// ページのアイコン（絵文字）→ メモの色。どれでもなければ色なし
  static String? _colorOf(String? emoji) => switch (emoji) {
        '🟥' => 'red',
        '🟧' => 'orange',
        '🟨' => 'yellow',
        '🟩' => 'green',
        '💠' => 'teal',
        '🟦' => 'blue',
        '🟪' => 'purple',
        '🌸' => 'pink',
        '⬜' => 'gray',
        _ => null,
      };

  static String _iconOf(String? colorKey) => switch (colorKey) {
        'red' => '🟥',
        'orange' => '🟧',
        'yellow' => '🟨',
        'green' => '🟩',
        'teal' => '💠',
        'blue' => '🟦',
        'purple' => '🟪',
        'pink' => '🌸',
        'gray' => '⬜',
        _ => '📝',
      };

  Future<Map<String, dynamic>> _request(String method, String path,
      [Map<String, dynamic>? body, Map<String, String>? query]) async {
    // Notionの利用制限（平均で1秒に3回まで）に引っかからないよう、少し間を空ける
    await Future<void>.delayed(const Duration(milliseconds: 350));
    final req = http.Request(method, Uri.https('api.notion.com', path, query))
      ..headers.addAll({
        'Authorization': 'Bearer ${notionToken.trim()}',
        'Notion-Version': _notionVersion,
      });
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    // 時間切れ（2026-11-18 B08）
    final res = await http.Response.fromStream(await req.send().timeout(const Duration(seconds: 30)))
        .timeout(const Duration(seconds: 30));
    final text = utf8.decode(res.bodyBytes);
    if (res.statusCode == 200) return jsonDecode(text) as Map<String, dynamic>;
    String message = text;
    try {
      message = (jsonDecode(text) as Map)['message'] as String? ?? text;
    } catch (_) {}
    if (res.statusCode == 404) throw _NotFound();
    if (res.statusCode == 401) {
      throw NotionException('Notionのトークン（NOTION_TOKEN）が正しくありません');
    }
    if (res.statusCode == 429) {
      throw NotionException('Notionへの送信が多すぎたため、少し待ってから送り直します');
    }
    // Notionの応答はそのまま画面に出さない（開発中だけターミナルへ。2026-11-18 B05）
    devLog('Notion APIエラー（${res.statusCode}）：$message');
    throw NotionException('Notionとのやり取りに失敗しました（${res.statusCode}）');
  }
}

class NotionException extends AppMessage {
  const NotionException(super.message);
}

class _NotFound implements Exception {}

/// 復元の候補になるNotionのページ（IDとタイトル）
class NotionPageRef {
  NotionPageRef(this.id, this.title);
  final String id;
  final String title;
}

/// アプリのメモの本文を、Notionに送るMarkdownにする。
/// アプリでは1回の改行もそのまま改行として表示しているが、Notionでは空行で区切らないと
/// 行が分かれないので、文章の行どうしの間に空行を入れる（箇条書き・引用・表・コードの中はそのまま）
String toNotionMarkdown(String body) {
  final fence = RegExp(r'^\s*(```|~~~)');
  final list = RegExp(r'^\s*([-*+]|\d+[.)])\s');
  final indented = RegExp(r'^\s+\S');
  final quote = RegExp(r'^\s*>');
  final table = RegExp(r'^\s*\|');
  final lines = body.replaceAll('\r\n', '\n').split('\n');
  final out = <String>[];
  var inFence = false;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    out.add(l);
    final next = i + 1 < lines.length ? lines[i + 1] : null;
    if (fence.hasMatch(l)) {
      inFence = !inFence;
      // コードの終わりのすぐ後に文章が続くときは空行を入れる
      if (!inFence && next != null && next.trim().isNotEmpty) out.add('');
      continue;
    }
    if (inFence || next == null) continue;
    if (l.trim().isEmpty || next.trim().isEmpty) continue;
    if (fence.hasMatch(next)) {
      out.add('');
      continue;
    }
    final inList = list.hasMatch(l) || indented.hasMatch(l);
    if (list.hasMatch(next) && inList) continue; // 箇条書きの続き
    if (indented.hasMatch(next) && inList) continue; // 入れ子の箇条書き
    if (quote.hasMatch(l) && quote.hasMatch(next)) continue;
    if (table.hasMatch(l) && table.hasMatch(next)) continue;
    out.add('');
  }
  return out.join('\n');
}

/// Notionから読み出したMarkdown（v2）を、アプリのメモの本文に戻す（2026-11-18。復元用）
/// - `<todo checked="…">…</todo>` → 「- [ ] …」「- [x] …」
/// - `<p />`・`<empty-block/>`（空の段落）→ 空行、`<br>`・行末の `\` → 改行、`\<` → `<`
/// - 色の付いた見出し・段落・文字（`<h2 color=…>`・`<p color=…>`・`<span color=…>`）は色を外す
/// - 入れ子のタブ → 空白2つ
/// - 送るときに補った空行（toNotionMarkdown）を外す。空行が2つ以上続くところは1つ残す。コードの中はそのまま
/// （JavaScriptに写して試験済み）
String fromNotionMarkdown(String md) {
  const blank = '\u0000BLANK\u0000';
  final fence = RegExp(r'^\s*(```|~~~)');
  final lines = md.replaceAll('\r\n', '\n').split('\n');
  final step1 = <String>[];
  var inFence = false;
  for (final raw in lines) {
    if (fence.hasMatch(raw)) {
      inFence = !inFence;
      step1.add(raw);
      continue;
    }
    if (inFence) {
      step1.add(raw);
      continue;
    }
    final lead = RegExp(r'^\t+').firstMatch(raw);
    var l = lead == null ? raw : '  ' * lead.group(0)!.length + raw.substring(lead.end);
    if (RegExp(r'^<(p|empty-block)\s*/>$').hasMatch(l.trim())) {
      step1.add(blank);
      continue;
    }
    l = l.replaceAllMapped(RegExp(r'^(\s*)<todo\b([^>]*)>(.*?)</todo>\s*$'),
        (m) => '${m[1]}- [${m[2]!.contains('checked="true"') ? 'x' : ' '}] ${m[3]}');
    l = l.replaceAllMapped(RegExp(r'^(\s*)<h([1-6])\b[^>]*>(.*?)</h\2>\s*$'),
        (m) => '${m[1]}${'#' * int.parse(m[2]!)} ${m[3]}');
    l = l.replaceAllMapped(RegExp(r'^(\s*)<p\b[^>]*>(.*?)</p>\s*$'), (m) => '${m[1]}${m[2]}');
    l = l.replaceAllMapped(RegExp(r'<span\b[^>]*>(.*?)</span>'), (m) => m[1]!);
    if (l.endsWith(r'\') && !l.endsWith(r'\\')) l = l.substring(0, l.length - 1);
    l = l.replaceAll(RegExp(r'<br\s*/?>'), '\n');
    l = l.replaceAll(r'\<', '<');
    step1.addAll(l.split('\n'));
  }
  final out = <String>[];
  inFence = false;
  for (var i = 0; i < step1.length; i++) {
    final l = step1[i];
    if (fence.hasMatch(l)) inFence = !inFence;
    if (!inFence && l.trim().isEmpty) {
      final prev = out.isEmpty ? null : out.last;
      final next = i + 1 < step1.length ? step1[i + 1] : null;
      if (prev == null || next == null || prev.trim().isEmpty || prev == blank) continue;
      if (next.trim().isNotEmpty && next != blank) continue; // 1つだけの空行 → 外す
      out.add(''); // 2つ以上続く空行 → 1つ残す
      continue;
    }
    out.add(l);
  }
  return out.map((l) => l == blank ? '' : l).join('\n').replaceFirst(RegExp(r'\s+$'), '');
}
