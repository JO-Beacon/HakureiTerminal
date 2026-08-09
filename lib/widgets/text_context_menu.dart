import 'package:flutter/material.dart';

/// 中文文本编辑右键菜单：始终提供剪切、复制、粘贴、全选。
/// 不适用的操作显示为禁用；密码字段不提供剪切/复制。
Widget jovTextContextMenu(
  BuildContext context,
  EditableTextState editableTextState,
) {
  final value = editableTextState.textEditingValue;
  final hasSelection = !value.selection.isCollapsed;
  final hasText = value.text.isNotEmpty;
  final obscured = editableTextState.widget.obscureText;
  final readOnly = editableTextState.widget.readOnly;
  final allSelected =
      hasText &&
      value.selection.start == 0 &&
      value.selection.end == value.text.length;

  final items = <ContextMenuButtonItem>[
    if (!obscured)
      ContextMenuButtonItem(
        label: '剪切',
        onPressed: hasSelection && !readOnly
            ? () =>
                  editableTextState.cutSelection(SelectionChangedCause.toolbar)
            : null,
      ),
    if (!obscured)
      ContextMenuButtonItem(
        label: '复制',
        onPressed: hasSelection
            ? () =>
                  editableTextState.copySelection(SelectionChangedCause.toolbar)
            : null,
      ),
    ContextMenuButtonItem(
      label: '粘贴',
      onPressed: readOnly
          ? null
          : () => editableTextState.pasteText(SelectionChangedCause.toolbar),
    ),
    ContextMenuButtonItem(
      label: '全选',
      onPressed: hasText && !allSelected
          ? () => editableTextState.selectAll(SelectionChangedCause.toolbar)
          : null,
    ),
  ];

  final theme = Theme.of(context);
  if (theme.platform == TargetPlatform.windows ||
      theme.platform == TargetPlatform.linux) {
    final menuTextStyle = TextStyle(
      fontFamily: theme.textTheme.bodyMedium?.fontFamily,
      fontFamilyFallback: theme.textTheme.bodyMedium?.fontFamilyFallback,
      fontSize: theme.textTheme.bodyMedium?.fontSize ?? 14,
      fontWeight: FontWeight.w400,
    );
    return AdaptiveTextSelectionToolbar(
      anchors: editableTextState.contextMenuAnchors,
      children: items
          .map(
            (item) => DesktopTextSelectionToolbarButton(
              onPressed: item.onPressed,
              child: Text(
                item.label!,
                overflow: TextOverflow.ellipsis,
                style: menuTextStyle,
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: items,
  );
}
