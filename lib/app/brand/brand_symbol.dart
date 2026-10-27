import 'package:flutter/material.dart';

/// The Floresta symbol from `assets/icon.svg` (viewBox 27 x 25, y down): six
/// rectangles on a 4.546-unit grid. Kept as geometry so the splash screen can
/// animate each block; `tool/brand/render_app_icon.swift` draws the app icon
/// from the same numbers.
abstract final class BrandSymbol {
  static const width = 26.5188;
  static const height = 24.2458;

  /// In the order the splash builds them: top-left blocks first, then the
  /// stem, the arms.
  static const blocks = <Rect>[
    Rect.fromLTWH(4.54609, 0, 4.54608, 4.54609),
    Rect.fromLTWH(0, 4.54609, 4.54609, 4.54608),
    Rect.fromLTWH(4.54609, 9.09217, 4.54608, 4.54613),
    Rect.fromLTWH(9.09217, 4.54609, 17.42663, 4.54608),
    Rect.fromLTWH(9.09217, 13.6383, 10.60753, 4.546),
    Rect.fromLTWH(9.09217, 13.6383, 4.54613, 10.6075),
  ];
}

/// Paints the symbol; [progress] (0..1 per block) lets each block grow in.
class BrandSymbolPainter extends CustomPainter {
  BrandSymbolPainter({required this.color, required this.progress});

  final Color color;

  /// One value per block in [BrandSymbol.blocks], each 0 (hidden) to 1.
  final List<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / BrandSymbol.width;
    for (var i = 0; i < BrandSymbol.blocks.length; i++) {
      final p = progress[i].clamp(0.0, 1.0);
      if (p == 0) continue;
      final r = BrandSymbol.blocks[i];
      final rect = Rect.fromLTWH(
        r.left * scale,
        r.top * scale,
        r.width * scale,
        r.height * scale,
      );
      // Each block rises a little and settles at full size.
      final grown = Rect.fromCenter(
        center: rect.center.translate(0, (1 - p) * rect.shortestSide * 0.6),
        width: rect.width * (0.7 + 0.3 * p),
        height: rect.height * (0.7 + 0.3 * p),
      );
      canvas.drawRect(grown, Paint()..color = color.withValues(alpha: p));
    }
  }

  @override
  bool shouldRepaint(BrandSymbolPainter old) =>
      old.color != color || old.progress != progress;
}
