import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// アプリの設定（端末に保存され、次回起動時も引き継がれる）
final appSettings = AppSettings();

class AppSettings extends ChangeNotifier {
  SharedPreferences? _prefs;

  /// 予定・タスク・メモの保存後にお知らせを出すか
  bool showSavedNotice = true;

  /// お知らせを表示する秒数
  int noticeSeconds = 4;

  /// アプリの起動時に自動で読み込むか
  bool autoReloadOnStart = true;

  /// メールの最初の画面（トップ画面）に戻ったときに自動で読み込むか
  bool autoReloadOnTop = true;

  /// 外観（システムに合わせる／ライト／ダーク）
  ThemeMode themeMode = ThemeMode.system;

  /// メール内の画像を自動で表示するか（オフなら「画像を表示」を押したときだけ）
  bool loadImages = false;

  // ---- カレンダーの設定 ----

  /// 今日から何日先まで予定を表示するか
  int calendarDays = 60;

  /// 時刻ありの予定を追加するときの、標準の長さ（分）
  int eventMinutes = 60;

  /// 週の始まりを月曜にするか（false なら日曜）。日付選択のカレンダーに使う
  bool weekStartsMonday = false;

  /// 月表示で、予定のある日に付ける印（0＝点、1＝件数、2＝色付きの丸）
  int calendarMarker = 0;

  /// カレンダーを開いたときの表示（true＝最後に使った表示、false＝いつも一覧）
  bool calendarRememberView = true;

  /// 最後に使った表示が月表示か
  bool calendarMonthView = false;

  // ---- タスクの設定 ----

  /// 完了したタスクも一覧に表示するか
  bool showCompletedTasks = true;

  // ---- メモの設定 ----

  /// メモをNotionに保存するか（2026-11-17）
  bool notionSync = false;

  // ---- AIの設定（2026-11-18 セキュリティ対策 A06） ----

  /// ✨に、ほかのタブの内容（予定・タスク・メモ・受信メール）も見せるか。初期値はオフ
  bool aiCrossTab = false;

  /// AIに送る内容の説明を読んで「使う」を押したか（初回だけ説明を出す）
  bool aiConsent = false;

  /// 「端末内のデータを消す」のあと：設定を初期値に戻す（2026-11-18。上の初期値と同じにすること）
  void resetToDefaults() {
    showSavedNotice = true;
    noticeSeconds = 4;
    autoReloadOnStart = true;
    autoReloadOnTop = true;
    themeMode = ThemeMode.system;
    loadImages = false;
    calendarDays = 60;
    eventMinutes = 60;
    weekStartsMonday = false;
    calendarMarker = 0;
    calendarRememberView = true;
    calendarMonthView = false;
    showCompletedTasks = true;
    notionSync = false;
    aiCrossTab = false;
    aiConsent = false;
    notifyListeners();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    showSavedNotice = p.getBool('showSavedNotice') ?? showSavedNotice;
    noticeSeconds = p.getInt('noticeSeconds') ?? noticeSeconds;
    // 以前の「自動で読み込む」（1つのスイッチ）の値を、2つの初期値として引き継ぐ
    final old = p.getBool('autoReload');
    autoReloadOnStart = p.getBool('autoReloadOnStart') ?? old ?? autoReloadOnStart;
    autoReloadOnTop = p.getBool('autoReloadOnTop') ?? old ?? autoReloadOnTop;
    themeMode = ThemeMode.values[p.getInt('themeMode') ?? themeMode.index];
    loadImages = p.getBool('loadImages') ?? loadImages;
    calendarDays = p.getInt('calendarDays') ?? calendarDays;
    eventMinutes = p.getInt('eventMinutes') ?? eventMinutes;
    weekStartsMonday = p.getBool('weekStartsMonday') ?? weekStartsMonday;
    calendarMarker = p.getInt('calendarMarker') ?? calendarMarker;
    calendarRememberView = p.getBool('calendarRememberView') ?? calendarRememberView;
    calendarMonthView = p.getBool('calendarMonthView') ?? calendarMonthView;
    showCompletedTasks = p.getBool('showCompletedTasks') ?? showCompletedTasks;
    notionSync = p.getBool('notionSync') ?? notionSync;
    aiCrossTab = p.getBool('aiCrossTab') ?? aiCrossTab;
    aiConsent = p.getBool('aiConsent') ?? aiConsent;
    notifyListeners();
  }

  void setShowSavedNotice(bool v) {
    showSavedNotice = v;
    _prefs?.setBool('showSavedNotice', v);
    notifyListeners();
  }

  void setNoticeSeconds(int v) {
    noticeSeconds = v;
    _prefs?.setInt('noticeSeconds', v);
    notifyListeners();
  }

  void setAutoReloadOnStart(bool v) {
    autoReloadOnStart = v;
    _prefs?.setBool('autoReloadOnStart', v);
    notifyListeners();
  }

  void setAutoReloadOnTop(bool v) {
    autoReloadOnTop = v;
    _prefs?.setBool('autoReloadOnTop', v);
    notifyListeners();
  }

  void setThemeMode(ThemeMode v) {
    themeMode = v;
    _prefs?.setInt('themeMode', v.index);
    notifyListeners();
  }

  void setLoadImages(bool v) {
    loadImages = v;
    _prefs?.setBool('loadImages', v);
    notifyListeners();
  }

  void setCalendarDays(int v) {
    calendarDays = v;
    _prefs?.setInt('calendarDays', v);
    notifyListeners();
  }

  void setEventMinutes(int v) {
    eventMinutes = v;
    _prefs?.setInt('eventMinutes', v);
    notifyListeners();
  }

  void setWeekStartsMonday(bool v) {
    weekStartsMonday = v;
    _prefs?.setBool('weekStartsMonday', v);
    notifyListeners();
  }

  void setCalendarMarker(int v) {
    calendarMarker = v;
    _prefs?.setInt('calendarMarker', v);
    notifyListeners();
  }

  void setCalendarRememberView(bool v) {
    calendarRememberView = v;
    _prefs?.setBool('calendarRememberView', v);
    notifyListeners();
  }

  void setCalendarMonthView(bool v) {
    calendarMonthView = v;
    _prefs?.setBool('calendarMonthView', v);
    notifyListeners();
  }

  void setShowCompletedTasks(bool v) {
    showCompletedTasks = v;
    _prefs?.setBool('showCompletedTasks', v);
    notifyListeners();
  }

  void setNotionSync(bool v) {
    notionSync = v;
    _prefs?.setBool('notionSync', v);
    notifyListeners();
  }

  void setAiCrossTab(bool v) {
    aiCrossTab = v;
    _prefs?.setBool('aiCrossTab', v);
    notifyListeners();
  }

  void setAiConsent(bool v) {
    aiConsent = v;
    _prefs?.setBool('aiConsent', v);
    notifyListeners();
  }
}
