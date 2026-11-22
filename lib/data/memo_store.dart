import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/errors.dart';
import 'models/memo.dart';

export 'models/memo.dart';

/// メモの保管場所（端末内に保存。アプリを閉じても消えない）
final memoStore = MemoStore();

class MemoStore extends ChangeNotifier {
  static const _key = 'memos';

  /// 並び順を「自分で並べた順」にしたか（2026-11-19 の19。なければ最初に更新の新しい順に並べる）
  static const _orderKey = 'memos_manual_order';

  /// 追加・変更・削除したときに呼ぶ（Notion連携が使う。main.dart で設定）
  static void Function(Memo m)? onSaved;
  static void Function(Memo m)? onRemoved;

  final List<Memo> _memos = [];
  SharedPreferences? _prefs;

  /// 自分で並べた順（一覧のドラッグで入れ替える。新しいメモはいちばん上。2026-11-19 の19）。
  /// 以前は更新日時の新しい順だった
  List<Memo> get memos => [..._memos];

  /// 一覧の中の位置（なければ -1）。スワイプ削除の「元に戻す」で元の位置に戻すのに使う
  int indexOf(String id) => _memos.indexWhere((m) => m.id == id);

  /// 端末に保存したメモを読み込む（起動時に1回）
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    final text = p.getString(_key);
    _memos.clear();
    if (text != null) {
      try {
        for (final j in jsonDecode(text) as List) {
          final m = Memo.fromJson(j);
          if (m != null) _memos.add(m);
        }
      } catch (e) {
        devLog('メモの読み込みに失敗: $e');
      }
    }
    // 並べ替えができる前のデータは、今までの見た目（更新の新しい順）を最初の並びにする
    if (p.getBool(_orderKey) != true) {
      _memos.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    _prefs = p;
    await p.setString(_key, jsonEncode(_memos.map((m) => m.toJson()).toList()));
    await p.setBool(_orderKey, true);
  }

  Memo? find(String id) {
    for (final m in _memos) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// メモを足す。新しいメモはいちばん上。[at] があればその位置（「元に戻す」で元の位置へ）
  Future<Memo> add(Memo m, {int? at}) async {
    _memos.insert((at ?? 0).clamp(0, _memos.length), m);
    notifyListeners();
    await _save();
    onSaved?.call(m);
    return m;
  }

  /// Notionから復元したメモをまとめて入れる（2026-11-18）。
  /// Notionへは送り返さないので onSaved は呼ばない
  Future<void> addRestored(List<Memo> list) async {
    // Notionには並び順がないので、更新の新しい順で入れる
    _memos.addAll([...list]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)));
    notifyListeners();
    await _save();
  }

  /// 「端末内のデータを消す」のあと（保存した分は消してあるので、画面の分だけ空にする。
  /// Notionのページはゴミ箱に入れないので onRemoved は呼ばない）
  void clearLocal() {
    _memos.clear();
    notifyListeners();
  }

  /// メモを書き換える（位置は動かさない）
  Future<Memo> update(Memo m) async {
    final i = _memos.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      _memos[i] = m;
    } else {
      _memos.insert(0, m);
    }
    notifyListeners();
    await _save();
    onSaved?.call(m);
    return m;
  }

  /// 一覧のドラッグで並べ替える（[from] の位置のメモを [to] の位置へ。to は動かしたあとの位置）
  Future<void> move(int from, int to) async {
    if (from < 0 || from >= _memos.length) return;
    final m = _memos.removeAt(from);
    _memos.insert(to.clamp(0, _memos.length), m);
    notifyListeners();
    await _save();
  }

  Future<void> remove(Memo m) async {
    _memos.removeWhere((x) => x.id == m.id);
    notifyListeners();
    await _save();
    onRemoved?.call(m);
  }
}
