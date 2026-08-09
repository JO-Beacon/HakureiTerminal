import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

class MarkdownMessage extends StatelessWidget {
  const MarkdownMessage({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return MarkdownBody(
      data: data,
      selectable: true,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      onTapLink: (_, href, _) => _openLink(context, href),
      builders: <String, MarkdownElementBuilder>{'pre': _CodeBlockBuilder()},
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        pPadding: EdgeInsets.zero,
        blockSpacing: 10,
        code: TextStyle(
          fontFamily: 'monospace',
          color: colorScheme.onSurfaceVariant,
          backgroundColor: colorScheme.surfaceContainerHighest,
        ),
        blockquoteDecoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest,
          border: Border(
            left: BorderSide(color: colorScheme.outline, width: 3),
          ),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        tableBorder: TableBorder.all(color: colorScheme.outlineVariant),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 6,
        ),
      ),
    );
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = Uri.tryParse(href ?? '');
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      _showNotice(context, '仅支持打开 HTTP/HTTPS 链接');
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      _showNotice(context, '无法打开链接');
    }
  }

  void _showNotice(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: const BorderRadius.all(Radius.circular(4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: '复制代码',
              icon: const Icon(Icons.copy_outlined, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
                if (context.mounted) {
                  ScaffoldMessenger.maybeOf(
                    context,
                  )?.showSnackBar(const SnackBar(content: Text('代码已复制')));
                }
              },
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: SelectableText(
              code,
              style: (preferredStyle ?? Theme.of(context).textTheme.bodyMedium)
                  ?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

String markdownToSpeechText(String source) {
  final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
  final nodes = document.parseLines(source.split('\n'));
  final output = StringBuffer();

  void visit(md.Node node, {bool skip = false}) {
    if (node is md.Text) {
      if (!skip) output.write(node.text);
      return;
    }
    if (node is! md.Element) return;
    final nextSkip = skip || node.tag == 'pre';
    for (final child in node.children ?? const <md.Node>[]) {
      visit(child, skip: nextSkip);
    }
    if (!nextSkip &&
        const <String>{
          'p',
          'li',
          'h1',
          'h2',
          'h3',
          'h4',
          'h5',
          'h6',
          'blockquote',
        }.contains(node.tag)) {
      output.write('\n');
    }
  }

  for (final node in nodes) {
    visit(node);
  }
  return output
      .toString()
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{2,}'), '\n')
      .trim();
}
