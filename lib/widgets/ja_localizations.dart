// MaterialLocalizationJa は material_ui パッケージへの移行で「非推奨」になっているが、
// このアプリは flutter/material.dart を使っているので、こちらを使う
// ignore_for_file: deprecated_member_use

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import '../data/app_settings.dart';

/// アプリの表示を日本語にする（日付選択・時刻選択など）。
/// 週の始まり（日曜／月曜）だけは「カレンダーの設定」に合わせる
final jaLocalizationsDelegates = <LocalizationsDelegate<dynamic>>[
  _JaMaterialLocalizationsDelegate(),
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
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
