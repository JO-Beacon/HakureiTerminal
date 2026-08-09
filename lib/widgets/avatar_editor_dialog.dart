import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/avatar_transform.dart';
import 'avatar_image.dart';

class AvatarEditorDialog extends StatefulWidget {
  const AvatarEditorDialog({
    super.key,
    required this.imageBytes,
    this.initialTransform = const AvatarTransform(),
  });

  final Uint8List imageBytes;
  final AvatarTransform initialTransform;

  @override
  State<AvatarEditorDialog> createState() => _AvatarEditorDialogState();
}

class _AvatarEditorDialogState extends State<AvatarEditorDialog> {
  static const double _previewDimension = 240;
  late AvatarTransform _transform;

  @override
  void initState() {
    super.initState();
    _transform = widget.initialTransform.normalized();
  }

  void _updateScale(double scale) {
    setState(() => _transform = _transform.copyWith(scale: scale));
  }

  void _move(DragUpdateDetails details) {
    setState(() {
      _transform = _transform.copyWith(
        offsetX: _transform.offsetX + details.delta.dx / _previewDimension,
        offsetY: _transform.offsetY + details.delta.dy / _previewDimension,
      );
    });
  }

  void _rotate(int delta) {
    setState(() {
      _transform = _transform.copyWith(
        rotationQuarterTurns: _transform.rotationQuarterTurns + delta,
      );
    });
  }

  void _reset() {
    setState(() => _transform = const AvatarTransform());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const ValueKey<String>('avatarEditorDialog'),
      title: const Text('编辑头像'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              GestureDetector(
                key: const ValueKey<String>('avatarCropGesture'),
                onPanUpdate: _transform.scale > 1 ? _move : null,
                child: MouseRegion(
                  cursor: _transform.scale > 1
                      ? SystemMouseCursors.move
                      : MouseCursor.defer,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        width: 2,
                      ),
                    ),
                    child: AvatarImage(
                      key: const ValueKey<String>('avatarEditorPreview'),
                      radius: _previewDimension / 2,
                      imageProvider: MemoryImage(widget.imageBytes),
                      transform: _transform,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: <Widget>[
                  const Icon(Icons.zoom_in_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Slider(
                      key: const ValueKey<String>('avatarZoomSlider'),
                      value: _transform.scale,
                      min: 1,
                      max: 3,
                      divisions: 40,
                      label: '${_transform.scale.toStringAsFixed(2)}×',
                      onChanged: _updateScale,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: <Widget>[
                  IconButton.outlined(
                    key: const ValueKey<String>('avatarRotateLeft'),
                    tooltip: '向左旋转 90°',
                    onPressed: () => _rotate(-1),
                    icon: const Icon(Icons.rotate_left_outlined),
                  ),
                  IconButton.outlined(
                    key: const ValueKey<String>('avatarTransformReset'),
                    tooltip: '重置裁剪与旋转',
                    onPressed: _reset,
                    icon: const Icon(Icons.restart_alt_outlined),
                  ),
                  IconButton.outlined(
                    key: const ValueKey<String>('avatarRotateRight'),
                    tooltip: '向右旋转 90°',
                    onPressed: () => _rotate(1),
                    icon: const Icon(Icons.rotate_right_outlined),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey<String>('avatarEditorApply'),
          onPressed: () => Navigator.of(context).pop(_transform.normalized()),
          child: const Text('应用头像'),
        ),
      ],
    );
  }
}
