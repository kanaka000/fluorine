// 日本語表示（2026-11-22 の18）：MaterialLocalizationJa・GlobalMaterialLocalizations は material_ui のものを使う
// （flutter_localizations から material_ui に移った）

import 'package:intl/intl.dart' as intl;
import 'package:material_ui/material_ui.dart';

import '../data/app_settings.dart';

/// アプリの表示を日本語にする（日付選択・時刻選択など）。
/// 週の始まり（日曜／月曜）だけは「カレンダーの設定」に合わせる
final jaLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  const _JaMaterialLocalizationsDelegate(),
  // 残り（ウィジェット・Cupertino など）は標準のもの。同じ種類は先に並べたもの（上の日本語）が使われる
  ...GlobalMaterialLocalizations.delegates,
];

class _JaMaterialLocalizationsDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _JaMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'ja';

  @override
  Future<MaterialLocalizations> load(Locale locale) async {
    // 標準の読み込みを先に呼んで、日本語の日付書式のデータを用意してもらう
    await GlobalMaterialLocalizations.delegate.load(locale);
    return _JaLocalizations();
  }

  @override
  bool shouldReload(_JaMaterialLocalizationsDelegate old) => false;
}

class _JaLocalizations extends MaterialLocalizationJa {
  _JaLocalizations()
      : super(
          fullYearFormat: intl.DateFormat.y('ja'),
          compactDateFormat: intl.DateFormat.yMd('ja'),
          shortDateFormat: intl.DateFormat.yMMMd('ja'),
          mediumDateFormat: intl.DateFormat.MMMEd('ja'),
          longDateFormat: intl.DateFormat.yMMMMEEEEd('ja'),
          yearMonthFormat: intl.DateFormat.yMMMM('ja'),
          shortMonthDayFormat: intl.DateFormat.MMMd('ja'),
          decimalFormat: intl.NumberFormat('#,##0.###', 'ja'),
          twoDigitZeroPaddedFormat: intl.NumberFormat('00', 'ja'),
        );

  /// 0＝日曜始まり、1＝月曜始まり（設定を変えると、次に日付選択を開いたときから反映）
  @override
  int get firstDayOfWeekIndex => appSettings.weekStartsMonday ? 1 : 0;
}
