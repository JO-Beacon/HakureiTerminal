import 'dart:async';

import 'package:flutter/material.dart';

OverlayEntry? _currentNotice;

/// 顶部通知横幅，替代底部 SnackBar；同一时间只保留一条。
void showTopNotice(BuildContext context, String message) {
  if (_currentNotice?.mounted == true) {
    _currentNotice!.remove();
  }
  _currentNotice = null;
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => _TopNoticeBanner(
      message: message,
      onDismiss: () {
        if (identical(_currentNotice, entry)) {
          _currentNotice = null;
        }
        if (entry.mounted) {
          entry.remove();
        }
      },
    ),
  );
  _currentNotice = entry;
  overlay.insert(entry);
}

class _TopNoticeBanner extends StatefulWidget {
  const _TopNoticeBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  State<_TopNoticeBanner> createState() => _TopNoticeBannerState();
}

class _TopNoticeBannerState extends State<_TopNoticeBanner> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(seconds: 4), widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Material(
                color: colorScheme.inverseSurface,
                elevation: 3,
                borderRadius: const BorderRadius.all(Radius.circular(4)),
                child: InkWell(
                  onTap: widget.onDismiss,
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            widget.message,
                            style: TextStyle(
                              color: colorScheme.onInverseSurface,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.close,
                          size: 16,
                          color: colorScheme.onInverseSurface,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
