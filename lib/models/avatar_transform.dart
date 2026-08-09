class AvatarTransform {
  const AvatarTransform({
    this.scale = 1,
    this.offsetX = 0,
    this.offsetY = 0,
    this.rotationQuarterTurns = 0,
  });

  final double scale;
  final double offsetX;
  final double offsetY;
  final int rotationQuarterTurns;

  @override
  bool operator ==(Object other) {
    return other is AvatarTransform &&
        other.scale == scale &&
        other.offsetX == offsetX &&
        other.offsetY == offsetY &&
        other.rotationQuarterTurns == rotationQuarterTurns;
  }

  @override
  int get hashCode =>
      Object.hash(scale, offsetX, offsetY, rotationQuarterTurns);

  AvatarTransform copyWith({
    double? scale,
    double? offsetX,
    double? offsetY,
    int? rotationQuarterTurns,
  }) {
    return AvatarTransform(
      scale: scale ?? this.scale,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      rotationQuarterTurns: rotationQuarterTurns ?? this.rotationQuarterTurns,
    ).normalized();
  }

  AvatarTransform normalized() {
    final nextScale = scale.isFinite ? scale.clamp(1.0, 3.0).toDouble() : 1.0;
    final maxOffset = (nextScale - 1) / 2;
    final nextOffsetX = offsetX.isFinite
        ? offsetX.clamp(-maxOffset, maxOffset).toDouble()
        : 0.0;
    final nextOffsetY = offsetY.isFinite
        ? offsetY.clamp(-maxOffset, maxOffset).toDouble()
        : 0.0;
    final nextRotation = rotationQuarterTurns.isFinite
        ? rotationQuarterTurns % 4
        : 0;
    return AvatarTransform(
      scale: nextScale,
      offsetX: nextOffsetX,
      offsetY: nextOffsetY,
      rotationQuarterTurns: nextRotation < 0 ? nextRotation + 4 : nextRotation,
    );
  }

  Map<String, dynamic> toJson() {
    final value = normalized();
    return <String, dynamic>{
      'scale': value.scale,
      'offset_x': value.offsetX,
      'offset_y': value.offsetY,
      'rotation_quarter_turns': value.rotationQuarterTurns,
    };
  }

  factory AvatarTransform.fromJson(Object? value) {
    if (value is! Map) {
      return const AvatarTransform();
    }
    final json = Map<String, dynamic>.from(value);
    return AvatarTransform(
      scale: _finiteDouble(json['scale'], 1),
      offsetX: _finiteDouble(json['offset_x'], 0),
      offsetY: _finiteDouble(json['offset_y'], 0),
      rotationQuarterTurns:
          int.tryParse(json['rotation_quarter_turns']?.toString() ?? '') ?? 0,
    ).normalized();
  }
}

double _finiteDouble(Object? value, double fallback) {
  final parsed = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');
  return parsed != null && parsed.isFinite ? parsed : fallback;
}
