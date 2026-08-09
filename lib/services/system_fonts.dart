/// 查询操作系统当前生效的界面字体。
///
/// 只读取用户系统设置，不内嵌、不分发任何字体文件：
/// - Windows: SystemParametersInfoW(SPI_GETNONCLIENTMETRICS) 的 lfMessageFont，
///   即用户在系统个性化里实际生效的 UI 字体。
/// - Linux: fontconfig 的 `fc-match sans-serif`，即发行版/用户字体配置的解析结果。
/// - 其余平台返回 null，交给 Flutter 平台默认字体栈（本身就是系统字体）。
library;

import 'dart:ffi';
import 'dart:io' show Platform, Process;

import 'package:flutter/foundation.dart' show kIsWeb;

String? _cachedFamily;
bool _resolved = false;

/// 系统 UI 字体族；查询失败时返回 null（由调用方决定候补）。结果进程内缓存。
String? systemUiFontFamily() {
  if (_resolved) {
    return _cachedFamily;
  }
  _resolved = true;
  if (kIsWeb) {
    return _cachedFamily;
  }
  try {
    if (Platform.isWindows) {
      _cachedFamily = _windowsMessageFontFamily();
    } else if (Platform.isLinux) {
      _cachedFamily = _linuxFontconfigFamily();
    }
  } catch (_) {
    _cachedFamily = null;
  }
  return _cachedFamily;
}

/// 系统字体缺失字形时的候补字体族，同样只引用系统字体。
List<String>? systemUiFontFallback() {
  if (kIsWeb) {
    return null;
  }
  if (Platform.isWindows) {
    return const <String>['Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI'];
  }
  if (Platform.isLinux) {
    return const <String>[
      'Noto Sans CJK SC',
      'WenQuanYi Micro Hei',
      'DejaVu Sans',
    ];
  }
  return null;
}

// ---------------------------------------------------------------------------
// Windows: SystemParametersInfoW(SPI_GETNONCLIENTMETRICS)
// ---------------------------------------------------------------------------

// NONCLIENTMETRICSW 布局（Vista+，含 iPaddedBorderWidth，共 504 字节）：
//   0   UINT cbSize
//   4   int  iBorderWidth
//   8   int  iScrollWidth
//   12  int  iScrollHeight
//   16  int  iCaptionWidth
//   20  int  iCaptionHeight
//   24  LOGFONTW lfCaptionFont      (92 字节)
//   116 int  iSmCaptionWidth
//   120 int  iSmCaptionHeight
//   124 LOGFONTW lfSmCaptionFont
//   216 int  iMenuWidth
//   220 int  iMenuHeight
//   224 LOGFONTW lfMenuFont
//   316 LOGFONTW lfStatusFont
//   408 LOGFONTW lfMessageFont      ← 对话框/一般 UI 文本字体
//   500 int  iPaddedBorderWidth
// LOGFONTW 内 lfFaceName 位于偏移 28，WCHAR[32]。
const int _ncmSize = 504;
const int _messageFontFaceNameOffset = 408 + 28;
const int _spiGetNonClientMetrics = 0x0029;

typedef _SystemParametersInfoWNative =
    Int32 Function(Uint32 uiAction, Uint32 uiParam, Pointer pvParam, Uint32);
typedef _SystemParametersInfoWDart =
    int Function(int uiAction, int uiParam, Pointer pvParam, int fWinIni);

String? _windowsMessageFontFamily() {
  final user32 = DynamicLibrary.open('user32.dll');
  final systemParametersInfoW = user32
      .lookupFunction<_SystemParametersInfoWNative, _SystemParametersInfoWDart>(
        'SystemParametersInfoW',
      );
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final processHeap = kernel32
      .lookupFunction<Pointer Function(), Pointer Function()>('GetProcessHeap')
      .call();
  final heapAlloc = kernel32
      .lookupFunction<
        Pointer Function(Pointer, Uint32, IntPtr),
        Pointer Function(Pointer, int, int)
      >('HeapAlloc');
  final heapFree = kernel32
      .lookupFunction<
        Int32 Function(Pointer, Uint32, Pointer),
        int Function(Pointer, int, Pointer)
      >('HeapFree');

  // HEAP_ZERO_MEMORY = 0x8
  final buffer = heapAlloc(processHeap, 0x8, _ncmSize).cast<Uint8>();
  if (buffer == nullptr) {
    return null;
  }
  try {
    buffer.cast<Uint32>().value = _ncmSize; // cbSize
    final ok = systemParametersInfoW(
      _spiGetNonClientMetrics,
      _ncmSize,
      buffer,
      0,
    );
    if (ok == 0) {
      return null;
    }
    final faceName = (buffer + _messageFontFaceNameOffset).cast<Uint16>();
    final units = <int>[];
    for (var i = 0; i < 32; i++) {
      final unit = (faceName + i).value;
      if (unit == 0) {
        break;
      }
      units.add(unit);
    }
    final family = String.fromCharCodes(units).trim();
    return family.isEmpty ? null : family;
  } finally {
    heapFree(processHeap, 0, buffer);
  }
}

// ---------------------------------------------------------------------------
// Linux: fontconfig
// ---------------------------------------------------------------------------

String? _linuxFontconfigFamily() {
  final result = Process.runSync('fc-match', <String>[
    '-f',
    '%{family[0]}',
    'sans-serif',
  ]);
  if (result.exitCode != 0) {
    return null;
  }
  final family = (result.stdout as String).trim();
  return family.isEmpty ? null : family;
}
