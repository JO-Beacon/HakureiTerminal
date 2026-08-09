import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'text_context_menu.dart';

/// 弹出颜色选择器对话框，返回用户确认的颜色；取消时返回 null。
Future<Color?> showColorPickerDialog({
  required BuildContext context,
  required String title,
  required Color initialColor,
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) =>
        _ColorPickerDialog(title: title, initialColor: initialColor),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.title, required this.initialColor});

  final String title;
  final Color initialColor;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late HSVColor _hsv;
  late final TextEditingController _hexController;

  Color get _color => _hsv.toColor();

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexController = TextEditingController(text: colorToHex(_color));
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _setHsv(HSVColor next, {bool syncHexField = true}) {
    setState(() => _hsv = next);
    if (syncHexField) {
      _hexController.text = colorToHex(_color);
    }
  }

  void _onHexChanged(String text) {
    final parsed = tryParseHexColor(text);
    if (parsed != null) {
      _setHsv(HSVColor.fromColor(parsed), syncHexField: false);
    }
  }

  void _setRgb({int? red, int? green, int? blue}) {
    final current = _color;
    _setHsv(
      HSVColor.fromColor(
        Color.fromARGB(
          255,
          red ?? _channel(current.r),
          green ?? _channel(current.g),
          blue ?? _channel(current.b),
        ),
      ),
    );
  }

  static int _channel(double value) => (value * 255).round().clamp(0, 255);

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 饱和度/明度面板，即画图软件里的取色方块。
              SizedBox(
                height: 180,
                child: _SaturationValuePanel(
                  hsv: _hsv,
                  onChanged: (next) => _setHsv(next),
                ),
              ),
              const SizedBox(height: 12),
              _HueSlider(hsv: _hsv, onChanged: (next) => _setHsv(next)),
              const SizedBox(height: 12),
              _RgbSliderRow(
                label: 'R',
                value: _channel(color.r),
                trackColor: Colors.red,
                onChanged: (value) => _setRgb(red: value),
              ),
              _RgbSliderRow(
                label: 'G',
                value: _channel(color.g),
                trackColor: Colors.green,
                onChanged: (value) => _setRgb(green: value),
              ),
              _RgbSliderRow(
                label: 'B',
                value: _channel(color.b),
                trackColor: Colors.blue,
                onChanged: (value) => _setRgb(blue: value),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: const BorderRadius.all(Radius.circular(4)),
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      contextMenuBuilder: jovTextContextMenu,
                      key: const ValueKey<String>('colorPickerHexField'),
                      controller: _hexController,
                      decoration: const InputDecoration(
                        labelText: 'HEX',
                        prefixText: '#',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(
                          RegExp('[0-9a-fA-F#]'),
                        ),
                        LengthLimitingTextInputFormatter(7),
                      ],
                      onChanged: _onHexChanged,
                    ),
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
          key: const ValueKey<String>('colorPickerConfirm'),
          onPressed: () => Navigator.of(context).pop(color),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 把颜色格式化成不带 # 的六位大写 HEX。
String colorToHex(Color color) {
  return (color.toARGB32() & 0xffffff)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();
}

/// 解析 3 位或 6 位 HEX（可带 #）；非法输入返回 null。
Color? tryParseHexColor(String text) {
  var hex = text.trim().replaceFirst('#', '');
  if (hex.length == 3) {
    hex = hex.split('').map((c) => '$c$c').join();
  }
  if (hex.length != 6) {
    return null;
  }
  final value = int.tryParse(hex, radix: 16);
  if (value == null) {
    return null;
  }
  return Color(0xff000000 | value);
}

class _SaturationValuePanel extends StatelessWidget {
  const _SaturationValuePanel({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _handle(Offset localPosition, Size size) {
    final saturation = (localPosition.dx / size.width).clamp(0.0, 1.0);
    final value = 1 - (localPosition.dy / size.height).clamp(0.0, 1.0);
    onChanged(hsv.withSaturation(saturation).withValue(value));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          onPanDown: (details) => _handle(details.localPosition, size),
          onPanUpdate: (details) => _handle(details.localPosition, size),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child: CustomPaint(
              size: size,
              painter: _SaturationValuePainter(hsv: hsv),
            ),
          ),
        );
      },
    );
  }
}

class _SaturationValuePainter extends CustomPainter {
  const _SaturationValuePainter({required this.hsv});

  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 水平：白 → 纯色相；垂直：透明 → 黑。叠加即饱和度/明度平面。
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            Colors.white,
            HSVColor.fromAHSV(1, hsv.hue, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.transparent, Colors.black],
        ).createShader(rect),
    );
    // 当前位置指示框（方形，符合全局去圆形规范）。
    final position = Offset(
      hsv.saturation * size.width,
      (1 - hsv.value) * size.height,
    );
    final indicator = Rect.fromCenter(center: position, width: 12, height: 12);
    canvas.drawRect(
      indicator,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    canvas.drawRect(
      indicator.inflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_SaturationValuePainter oldDelegate) {
    return oldDelegate.hsv != hsv;
  }
}

class _HueSlider extends StatelessWidget {
  const _HueSlider({required this.hsv, required this.onChanged});

  final HSVColor hsv;
  final ValueChanged<HSVColor> onChanged;

  void _handle(Offset localPosition, double width) {
    final hue = (localPosition.dx / width).clamp(0.0, 1.0) * 360;
    onChanged(hsv.withHue(hue == 360 ? 0 : hue));
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          onPanDown: (details) => _handle(details.localPosition, width),
          onPanUpdate: (details) => _handle(details.localPosition, width),
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(4)),
            child: CustomPaint(
              size: Size(width, 20),
              painter: _HueTrackPainter(hue: hsv.hue),
            ),
          ),
        );
      },
    );
  }
}

class _HueTrackPainter extends CustomPainter {
  const _HueTrackPainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            for (var i = 0; i <= 6; i++)
              HSVColor.fromAHSV(
                1,
                i * 60.0 == 360 ? 0 : i * 60.0,
                1,
                1,
              ).toColor(),
          ],
        ).createShader(rect),
    );
    final x = (hue / 360) * size.width;
    final indicator = Rect.fromCenter(
      center: Offset(x, size.height / 2),
      width: 8,
      height: size.height + 2,
    );
    canvas.drawRect(
      indicator,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white,
    );
    canvas.drawRect(
      indicator.inflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.black54,
    );
  }

  @override
  bool shouldRepaint(_HueTrackPainter oldDelegate) => oldDelegate.hue != hue;
}

class _RgbSliderRow extends StatelessWidget {
  const _RgbSliderRow({
    required this.label,
    required this.value,
    required this.trackColor,
    required this.onChanged,
  });

  final String label;
  final int value;
  final Color trackColor;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 16,
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(
          child: Slider(
            value: value.toDouble(),
            max: 255,
            activeColor: trackColor,
            onChanged: (next) => onChanged(next.round()),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            '$value',
            textAlign: TextAlign.end,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
