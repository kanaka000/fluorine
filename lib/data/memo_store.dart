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

  /// 追加・変更・削除したときに呼ぶ（Notion連携が使う。main.dart で設定）
  static void Function(Memo m)? onSaved;
  static void Function(Memo m)? onRemoved;

  final List<Memo> _memos = [];
  SharedPreferences? _prefs;

  /// 更新日時の新しい順（新規メモは作成日時＝更新日時）
  List<Memo> get memos => [..._memos]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

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
    notifyListeners();
  }

  Future<void> _save() async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    _prefs = p;
    await p.setString(_key, jsonEncode(_memos.map((m) => m.toJson()).toList()));
  }

  Memo? find(String id) {
    for (final m in _memos) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<Memo> add(Memo m) async {
    _memos.add(m);
    notifyListeners();
    await _save();
    onSaved?.call(m);
    return m;
  }

  /// Notionから復元したメモをまとめて入れる（2026-11-18）。
  /// Notionへは送り返さないので onSaved は呼ばない
  Future<void> addRestored(List<Memo> list) async {
    _memos.addAll(list);
    notifyListeners();
    await _save();
  }

  /// 「端末内のデータを消す」のあと（保存した分は消してあるので、画面の分だけ空にする。
  /// Notionのページはゴミ箱に入れないので onRemoved は呼ばない）
  void clearLocal() {
    _memos.clear();
    notifyListeners();
  }

  Future<Memo> update(Memo m) async {
    final i = _memos.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      _memos[i] = m;
    } else {
      _memos.add(m);
    }
    notifyListeners();
    await _save();
    onSaved?.call(m);
    return m;
  }

  Future<void> remove(Memo m) async {
    _memos.removeWhere((x) => x.id == m.id);
    notifyListeners();
    await _save();
    onRemoved?.call(m);
  }
}
