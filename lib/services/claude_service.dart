import '../data/models.dart';
import 'errors.dart';
import '../util/date_text.dart';
import 'ai/claude_client.dart';
import 'ai/ai_tools.dart';
import 'ai/ai_context.dart';
import 'ai/ai_results.dart';
import '../util/html_text.dart';

export 'ai/ai_results.dart';

/// ✨（Claude）への頼みごと。道具・参考情報・安全対策は services/ai/ に分けた（2026-11-19 の整理）
class ClaudeService {
  /// APIキーが使えるか（空白・見本のままなら false）
  static bool get available => claudeAvailable;

  /// 指示に従って返信の下書きを作る
  static Future<String> draftReply({
    required Mail original,
    required String instruction,
    required String currentDraft,
    bool forward = false,
  }) async {
    checkClaudeKey();
    final lead = forward
        ? 'あなたはメールの転送に添えるメッセージの下書きを手伝うアシスタントです。'
            '元のメールは自動で下に付くので、ユーザーの指示に従い、転送先の相手に向けて添える文だけを出力してください。'
        : 'あなたはメールの返信の下書きを手伝うアシスタントです。'
            'ユーザーの指示に従い、返信メールの本文だけを出力してください。';
    final system = '$lead件名・宛先・前置き・説明・引用（>）・署名は出力しないでください。'
        '元のメールが日本語なら日本語で、それ以外の言語ならその言語で書いてください。'
        '今の下書きがある場合は、それを指示に従って書き直してください。'
        '指示が音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。';

    final user = '## 元のメール\n'
        '差出人: ${original.senderName} <${original.senderAddress}>\n'
        '件名: ${original.subject}\n'
        '本文:\n${wrapAiData(clipForAi(original.body, 30000))}\n\n'
        '## 今の下書き\n${currentDraft.trim().isEmpty ? '（まだありません）' : currentDraft}\n\n'
        '## 指示\n$instruction';

    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 1500,
      'system': system,
      'messages': [
        {'role': 'user', 'content': user},
      ],
    });
    final parts = (json['content'] as List)
        .where((c) => c['type'] == 'text')
        .map((c) => c['text'] as String);
    return parts.join().trim();
  }

  /// 新規メールの下書き（件名と本文）を作る
  static Future<({String subject, String body})> draftNewMail({
    required String instruction,
    required String currentDraft,
    required String currentSubject,
    required String to,
  }) async {
    checkClaudeKey();
    const system = 'あなたは新しいメールの下書きを手伝うアシスタントです。'
        'ユーザーの指示に従い、write_mail を使って件名と本文を作ってください。'
        '本文には宛先・署名・説明・前置きを入れないでください。'
        '今の下書きがある場合は、それを指示に従って書き直してください。'
        '指示が音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。';
    final user = '## 宛先\n${to.trim().isEmpty ? '（未入力）' : to}\n\n'
        '## 今の件名\n${currentSubject.trim().isEmpty ? '（まだありません）' : currentSubject}\n\n'
        '## 今の下書き\n${currentDraft.trim().isEmpty ? '（まだありません）' : currentDraft}\n\n'
        '## 指示\n$instruction';
    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 1500,
      'system': system,
      'tools': [
        {
          'name': 'write_mail',
          'description': '新しいメールの件名と本文',
          'input_schema': {
            'type': 'object',
            'properties': {
              'subject': {'type': 'string', 'description': '件名（短く）'},
              'body': {'type': 'string', 'description': '本文'},
            },
            'required': ['subject', 'body'],
          },
        },
      ],
      'tool_choice': {'type': 'tool', 'name': 'write_mail'},
      'messages': [
        {'role': 'user', 'content': user},
      ],
    });
    for (final c in (json['content'] as List).cast<Map<String, dynamic>>()) {
      if (c['type'] == 'tool_use') {
        final input = (c['input'] as Map).cast<String, dynamic>();
        return (
          subject: (input['subject'] as String?)?.trim() ?? '',
          body: (input['body'] as String?)?.trim() ?? '',
        );
      }
    }
    throw const AppMessage('AIから下書きを受け取れませんでした。もう一度試してください');
  }

  /// 開いているメールについての頼みごとを、Claudeに1つの操作として選ばせる
  static Future<AiResult> askAboutMail({
    required Mail mail,
    required String instruction,
  }) async {
    checkClaudeKey();
    final today = aiTodayText();
    final system = 'あなたはメールアプリ「Fluorine」のアシスタントです。'
        'ユーザーが開いているメールについての頼みごとに対して、用意された道具を1つだけ使って応えてください。'
        '今日は$today です。「来週火曜」「明日」などの日付は今日を基準に計算してください。'
        '日時はメールの本文から読み取り、はっきりしない場合は推測しすぎず、分かる範囲で埋めてください。'
        '指示は音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。'
        '予定・タスク・メモ・返信はユーザーが確認してから保存・送信するので、下書きとして作ってください。'
        'このメールへの返信は draft_reply、別の人への新しいメールは draft_new_mail です。'
        '$aiLinkRule'
        '$aiCrossRule';
    var body = mail.body;
    if (body.length > 8000) body = '${body.substring(0, 8000)}\n（以下省略）';
    final user = '## 開いているメール\n'
        '差出人: ${mail.senderName} <${mail.senderAddress}>\n'
        '受信日時: ${mail.receivedAt}\n'
        '件名: ${mail.subject}\n'
        '本文:\n${wrapAiData(body)}\n\n'
        '${aiReferenceInfo()}\n'
        '## 頼みごと\n$instruction';
    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 1500,
      'system': system,
      'tools': [...mailTools, linkTool(const ['event', 'task'])],
      'tool_choice': {'type': 'any'},
      'messages': [
        {'role': 'user', 'content': user},
      ],
    });
    return aiResultFrom(claudeToolUse(json));
  }

  /// メールのトップ画面（送信元一覧）からの頼みごと。予定・タスク・メモ・メールの質問と新規作成
  static Future<AiResult> askAnything({required String instruction}) async {
    checkClaudeKey();
    final system = 'あなたはメール・カレンダー・タスク・メモをまとめたアプリ「Fluorine」のアシスタントです。'
        'ユーザーの頼みごとに対して、用意された道具を1つだけ使って応えてください。'
        '今は${aiTodayText()} です。「来週火曜」「明日」などの日付は今日を基準に計算してください。'
        '新しい予定は create_event、タスクは create_task、メモは create_memo、新しいメールは draft_new_mail を使ってください。'
        'メールを探す・見つける・検索するよう頼まれたら、参考情報から答えずに必ず search_mail を使ってください。'
        '予定・タスク・メモ・メールはユーザーが確認してから保存・送信するので、下書きとして作ってください。'
        '指示は音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。'
        '$aiCrossRule';
    final user = '${aiReferenceInfo()}\n## 頼みごと\n$instruction';
    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 2000,
      'system': system,
      'tools': [
        createEventTool,
        createTaskTool,
        createMemoTool,
        draftNewMailTool,
        searchMailTool,
        answerTool,
      ],
      'tool_choice': {'type': 'any'},
      'messages': [
        {'role': 'user', 'content': user},
      ],
    });
    return aiResultFrom(claudeToolUse(json));
  }

  /// カレンダーについての頼みごと。[selected] があれば、その予定を対象にする（予定の詳細画面から）
  static Future<AiResult> askAboutCalendar({
    required String instruction,
    required List<CalendarEvent> upcoming,
    CalendarEvent? selected,
  }) async {
    checkClaudeKey();
    final system = 'あなたはメール・カレンダーアプリ「Fluorine」のアシスタントです。'
        'ユーザーのカレンダーについての頼みごとに対して、用意された道具を1つだけ使って応えてください。'
        '今は${aiTodayText()} です。「来週火曜」「明日」などの日付は今日を基準に計算してください。'
        '${selected != null ? 'ユーザーは「選んでいる予定」を開いています。「これ」「この予定」はその予定のことです。'
            '場所・タイトル・メモ・時間の変更を頼まれたら update_event を使い、変える項目だけを入れてください。' : ''}'
        '新しい予定を頼まれたら create_event を使ってください。'
        '${selected == null ? '一覧にある予定の日時を変えるよう頼まれたら、新しい日時で create_event を使い、'
            'replaces に元の予定の番号を入れてください。タイトル・場所は元の予定から引き継いでください。' : ''}'
        '「明日の予定は？」「空いている日は？」などの質問には、予定の一覧を見て answer で答えてください。'
        '指示は音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。'
        '予定・タスク・メモはユーザーが確認してから保存するので、下書きとして作ってください。'
        '予定の削除を頼まれたら delete_event を使ってください（実際に削除するかはユーザーが確認画面で決めます）。'
        '${selected != null ? aiLinkRule : ''}'
        '$aiCrossRule';
    // 番号は1から（delete_event で予定を指すのに使う）
    final shown = upcoming.take(150).toList();
    final list = [for (var i = 0; i < shown.length; i++) '- [${i + 1}] ${describeEvent(shown[i])}'].join('\n');
    final buf = StringBuffer();
    if (selected != null) {
      // 書式付き（HTML）のメモ欄は記号を外し、リンクは「文字（URL）」で渡す（2026-11-22）
      var note = eventNoteText(selected.note, keepLinks: true);
      if (note.length > 3000) note = '${note.substring(0, 3000)}（以下省略）';
      buf
        ..writeln('## 選んでいる予定')
        ..writeln(describeEvent(selected))
        ..writeln(selected.recurring ? '（繰り返しの予定の1回分）' : '')
        ..writeln(note.isEmpty ? 'メモ：なし' : 'メモ：\n$note')
        ..writeln();
    }
    buf
      ..writeln('## これからの予定（今日から${aiRangeText(upcoming)}）')
      ..writeln(list.isEmpty ? '（予定はありません）' : list)
      ..writeln()
      ..writeln(aiReferenceInfo(events: false))
      ..writeln('## 頼みごと')
      ..writeln(instruction);
    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 1500,
      'system': system,
      'tools': [
        createEventToolForCalendar,
        if (selected != null) updateEventTool,
        if (selected != null) linkTool(const ['memo', 'mail']),
        deleteEventTool,
        createTaskTool,
        createMemoTool,
        draftNewMailTool,
        answerTool,
      ],
      'tool_choice': {'type': 'any'},
      'messages': [
        {'role': 'user', 'content': buf.toString()},
      ],
    });
    return aiResultFrom(claudeToolUse(json));
  }

  /// タスクについての頼みごと。[selected] があれば、そのタスクを対象にする（タスクの詳細画面から）
  static Future<AiResult> askAboutTasks({
    required String instruction,
    required List<TaskItem> tasks,
    TaskItem? selected,
  }) async {
    checkClaudeKey();
    final system = 'あなたはメール・タスク管理アプリ「Fluorine」のアシスタントです。'
        'ユーザーのタスク（やること）についての頼みごとに対して、用意された道具を1つだけ使って応えてください。'
        '今は${aiTodayText()} です。「来週火曜」「明日」などの日付は今日を基準に計算してください。'
        '${selected != null ? 'ユーザーは「選んでいるタスク」を開いています。「これ」「このタスク」はそのタスクのことで、'
            'その場合 number は省略してください。' : '既にあるタスクを指すときは、一覧の番号を number に入れてください。'}'
        '新しいタスクは create_task、変更は update_task、完了は complete_task、削除は delete_task を使ってください。'
        '完了・削除はユーザーが確認画面で決めます。'
        '「期限が近いタスクは？」などの質問には、一覧を見て answer で答えてください。'
        '新しい予定を頼まれたら create_event を使ってください。'
        '${selected != null ? aiLinkRule : ''}'
        '指示は音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。'
        '$aiCrossRule';
    final shown = tasks.take(200).toList();
    final buf = StringBuffer();
    if (selected != null) {
      var note = (selected.note ?? '').trim();
      if (note.length > 3000) note = '${note.substring(0, 3000)}（以下省略）';
      buf
        ..writeln('## 選んでいるタスク')
        ..writeln(describeTask(selected))
        ..writeln(note.isEmpty ? 'メモ：なし' : 'メモ：\n$note')
        ..writeln();
    }
    buf
      ..writeln('## タスクの一覧')
      ..writeln(shown.isEmpty
          ? '（タスクはありません）'
          : [for (var i = 0; i < shown.length; i++) '- [${i + 1}] ${describeTask(shown[i])}'].join('\n'))
      ..writeln()
      ..writeln(aiReferenceInfo(tasks: false))
      ..writeln('## 頼みごと')
      ..writeln(instruction);
    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 1500,
      'system': system,
      'tools': [
        createTaskTool,
        updateTaskTool,
        completeTaskTool,
        deleteTaskTool,
        if (selected != null) linkTool(const ['memo', 'mail']),
        createMemoTool,
        createEventTool,
        draftNewMailTool,
        answerTool,
      ],
      'tool_choice': {'type': 'any'},
      'messages': [
        {'role': 'user', 'content': buf.toString()},
      ],
    });
    return aiResultFrom(claudeToolUse(json));
  }

  /// タスクの追加・変更画面のAIボタン：今の入力欄と頼みごとから、入力欄の中身を作る
  static Future<AiTask> fillTask({
    required String instruction,
    required String title,
    DateTime? due,
    required String note,
    String? source,
  }) async {
    checkClaudeKey();
    final system = 'あなたはタスク（やること）の入力を手伝うアシスタントです。'
        'ユーザーの頼みごとに従い、fill_task でタスクの名前・期限・メモを作ってください。'
        '今の入力欄に内容があれば、それをもとに頼まれたところだけ直してください。'
        '今は${aiTodayText()} です。「来週火曜」「明日」などの日付は今日を基準に計算してください。'
        '名前は短く、動詞で終えてください。'
        '指示は音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。';
    var src = (source ?? '').trim();
    if (src.length > 6000) src = '${src.substring(0, 6000)}（以下省略）';
    final dueText = due == null ? 'なし' : '${due.year}-${pad2(due.month)}-${pad2(due.day)}';
    final user = '${src.isEmpty ? '' : '## 元の情報（メールなど）\n${wrapAiData(src)}\n\n'}'
        '## 今の入力欄\n名前：${title.trim().isEmpty ? '（空）' : title}\n期限：$dueText\n'
        'メモ：${note.trim().isEmpty ? '（空）' : note}\n\n'
        '## 頼みごと\n$instruction';
    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 1000,
      'system': system,
      'tools': [
        {
          'name': 'fill_task',
          'description': 'タスクの入力欄に入れる内容',
          'input_schema': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': 'やること（短く、動詞で終える）'},
              'due': {'type': 'string', 'description': '期限 YYYY-MM-DD。なければ省略'},
              'note': {'type': 'string', 'description': 'メモ（なければ空）'},
            },
            'required': ['title'],
          },
        },
      ],
      'tool_choice': {'type': 'tool', 'name': 'fill_task'},
      'messages': [
        {'role': 'user', 'content': user},
      ],
    });
    final use = claudeToolUse(json);
    if (use.name == null) throw const AppMessage('AIから入力内容を受け取れませんでした。もう一度試してください');
    String str(String k) => (use.input[k] as String?)?.trim() ?? '';
    return AiTask(title: str('title'), due: aiDate(use.input['due']), note: str('note'));
  }

  /// メモについての頼みごと。[selected] があれば、そのメモを対象にする（メモの詳細画面から）
  static Future<AiResult> askAboutMemos({
    required String instruction,
    required List<Memo> memos,
    Memo? selected,
  }) async {
    checkClaudeKey();
    final system = 'あなたはメール・メモアプリ「Fluorine」のアシスタントです。'
        'ユーザーのメモについての頼みごとに対して、用意された道具を1つだけ使って応えてください。'
        '今は${aiTodayText()} です。'
        '${selected != null ? 'ユーザーは「選んでいるメモ」を開いています。「これ」「このメモ」はそのメモのことで、'
            'その場合 number は省略してください。' : '既にあるメモを指すときは、一覧の番号を number に入れてください。'}'
        '新しいメモは create_memo、変更は update_memo、削除は delete_memo、メモからやることを作るなら create_task を使ってください。'
        '削除はユーザーが確認画面で決めます。変更や新しいメモも、ユーザーが確認してから保存します。'
        '質問（要約、○○のメモはどれ？など）には answer で答えてください。'
        '新しい予定を頼まれたら create_event を使ってください。'
        '${selected != null ? '$aiLinkRule$aiOpenMailRule' : ''}'
        '$memoMarkdownRule'
        '指示は音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。'
        '$aiCrossRule';
    final shown = memos.take(200).toList();
    String head(String body) {
      final b = body.replaceAll('\n', ' ').trim();
      return b.length > 120 ? '${b.substring(0, 120)}…' : b;
    }

    final buf = StringBuffer();
    if (selected != null) {
      var body = selected.body.trim();
      if (body.length > 6000) body = '${body.substring(0, 6000)}（以下省略）';
      buf
        ..writeln('## 選んでいるメモ')
        ..writeln('タイトル：${selected.title}')
        ..writeln('本文：\n${body.isEmpty ? '（空）' : body}')
        ..writeln();
    }
    buf
      ..writeln('## メモの一覧（一覧の画面の並び順）')
      ..writeln(shown.isEmpty
          ? '（メモはありません）'
          : [for (var i = 0; i < shown.length; i++) '- [${i + 1}] ${shown[i].title}：${head(shown[i].body)}'].join('\n'))
      ..writeln()
      ..writeln(aiReferenceInfo(memos: false))
      ..writeln('## 頼みごと')
      ..writeln(instruction);
    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 2000,
      'system': system,
      'tools': [
        createMemoTool,
        updateMemoTool,
        deleteMemoTool,
        if (selected != null) linkTool(const ['event', 'task']),
        if (selected != null) openMailTool,
        createTaskTool,
        createEventTool,
        draftNewMailTool,
        answerTool,
      ],
      'tool_choice': {'type': 'any'},
      'messages': [
        {'role': 'user', 'content': buf.toString()},
      ],
    });
    return aiResultFrom(claudeToolUse(json));
  }

  /// メモの追加・変更画面のAIボタン：今の入力欄と頼みごとから、タイトルと本文を作る
  static Future<AiMemo> fillMemo({
    required String instruction,
    required String title,
    required String body,
    String? source,
  }) async {
    checkClaudeKey();
    final system = 'あなたはメモの入力を手伝うアシスタントです。'
        'ユーザーの頼みごとに従い、fill_memo でメモのタイトルと本文を作ってください。'
        '今の入力欄に内容があれば、それをもとに頼まれたところだけ直してください（書き足し・整理・要約・箇条書きなど）。'
        '元の情報（メールなど）があれば参考にしてください。'
        '$memoMarkdownRule'
        '今は${aiTodayText()} です。'
        '指示は音声入力のため誤変換を含むことがあるので、文脈から意図をくみ取ってください。';
    var src = (source ?? '').trim();
    if (src.length > 6000) src = '${src.substring(0, 6000)}（以下省略）';
    final user = '${src.isEmpty ? '' : '## 元の情報（メールなど）\n${wrapAiData(src)}\n\n'}'
        '## 今の入力欄\nタイトル：${title.trim().isEmpty ? '（空）' : title}\n'
        '本文：\n${body.trim().isEmpty ? '（空）' : body}\n\n'
        '## 頼みごと\n$instruction';
    final json = await postToClaude({
      'model': claudeModel,
      'max_tokens': 2000,
      'system': system,
      'tools': [
        {
          'name': 'fill_memo',
          'description': 'メモの入力欄に入れる内容',
          'input_schema': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': 'タイトル（短く）'},
              'body': {'type': 'string', 'description': '本文全体'},
            },
            'required': ['title', 'body'],
          },
        },
      ],
      'tool_choice': {'type': 'tool', 'name': 'fill_memo'},
      'messages': [
        {'role': 'user', 'content': user},
      ],
    });
    final use = claudeToolUse(json);
    if (use.name == null) throw const AppMessage('AIから入力内容を受け取れませんでした。もう一度試してください');
    String str(String k) => (use.input[k] as String?)?.trim() ?? '';
    return AiMemo(title: str('title'), body: str('body'));
  }
}
