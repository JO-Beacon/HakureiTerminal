import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/avatar_transform.dart';

class AvatarImage extends StatelessWidget {
  const AvatarImage({
    super.key,
    required this.radius,
    this.imageProvider,
    this.transform = const AvatarTransform(),
    this.placeholderIcon = Icons.account_circle_outlined,
    this.placeholderIconSize,
  });

  final double radius;
  final ImageProvider? imageProvider;
  final AvatarTransform transform;
  final IconData placeholderIcon;
  final double? placeholderIconSize;

  @override
  Widget build(BuildContext context) {
    final dimension = radius * 2;
    final normalized = transform.normalized();
    final colorScheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          placeholderIcon,
          size: placeholderIconSize ?? radius * 1.08,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final provider = imageProvider;
    return ClipOval(
      child: SizedBox.square(
        dimension: dimension,
        child: provider == null
            ? placeholder
            : Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  placeholder,
                  Transform.translate(
                    offset: Offset(
                      normalized.offsetX * dimension,
                      normalized.offsetY * dimension,
                    ),
                    child: Transform.rotate(
                      angle: normalized.rotationQuarterTurns * math.pi / 2,
                      child: Transform.scale(
                        scale: normalized.scale,
                        child: Image(
                          image: provider,
                          fit: BoxFit.cover,
                          width: dimension,
                          height: dimension,
                          errorBuilder: (_, _, _) => placeholder,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
