import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hakurei_terminal/widgets/markdown_message.dart';

void main() {
  test('speech text excludes fenced code and keeps readable content', () {
    final text = markdownToSpeechText('''
# 标题

这里有 **重点** 和 [链接](https://example.com)。

```dart
print('不要朗读');
```

- 第一项
- 第二项
''');

    expect(text, contains('标题'));
    expect(text, contains('这里有 重点 和 链接。'));
    expect(text, contains('第一项'));
    expect(text, isNot(contains('不要朗读')));
    expect(text, isNot(contains('https://example.com')));
  });

  testWidgets('renders markdown and exposes code copy action', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownMessage(data: '**粗体**\n\n```dart\nvoid main() {}\n```'),
        ),
      ),
    );

    expect(find.text('粗体'), findsOneWidget);
    expect(find.text('void main() {}'), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);
  });
}
