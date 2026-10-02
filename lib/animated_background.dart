import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 最初の画面(ファイル未選択時)の背景。暗い夜空のようなグラデーションの上を
/// 色とりどりの光の玉がゆっくり漂い、細かな光の粒が瞬きながら昇っていく。
/// 「SDRの暗い画面に光が差してHDRになる」イメージ。
///
/// 1周期([_period])でぴったり元の位置に戻るよう、各軌道の周波数は整数に
/// してあるので、ループの継ぎ目で動きが飛ばない。
class AnimatedHdrBackground extends StatefulWidget {
  const AnimatedHdrBackground({super.key});

  @override
  State<AnimatedHdrBackground> createState() => _AnimatedHdrBackgroundState();
}

class _AnimatedHdrBackgroundState extends State<AnimatedHdrBackground>
    with SingleTickerProviderStateMixin {
  static const _period = Duration(seconds: 40);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _period,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BackgroundPainter(_controller),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Orb {
  const _Orb({
    required this.color,
    required this.center,
    required this.amplitude,
    required this.freq,
    required this.phase,
    required this.radius,
  });

  final Color color;
  // 画面サイズに対する比率(0〜1)。
  final Offset center;
  final Offset amplitude;
  // 1周期あたりのx/y方向の往復回数(整数でないとループが繋がらない)。
  final (int, int) freq;
  final double phase;
  // 画面の短辺に対する比率。
  final double radius;
}

class _Particle {
  _Particle(math.Random r)
    : x = r.nextDouble(),
      y = r.nextDouble(),
      size = 0.6 + r.nextDouble() * 1.6,
      rise = 1 + r.nextInt(3),
      twinkle = 2 + r.nextInt(6),
      phase = r.nextDouble() * math.pi * 2;

  final double x;
  final double y;
  final double size;
  // 1周期で画面を何回分昇るか(整数)。
  final int rise;
  // 1周期で何回瞬くか(整数)。
  final int twinkle;
  final double phase;
}

class _BackgroundPainter extends CustomPainter {
  _BackgroundPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  static const _orbs = [
    _Orb(
      color: Color(0xFF3D5AFE),
      center: Offset(0.25, 0.3),
      amplitude: Offset(0.18, 0.12),
      freq: (1, 2),
      phase: 0,
      radius: 0.75,
    ),
    _Orb(
      color: Color(0xFFE040FB),
      center: Offset(0.8, 0.25),
      amplitude: Offset(0.15, 0.18),
      freq: (2, 1),
      phase: 1.7,
      radius: 0.6,
    ),
    _Orb(
      color: Color(0xFFFF9100),
      center: Offset(0.7, 0.8),
      amplitude: Offset(0.2, 0.1),
      freq: (1, 1),
      phase: 3.1,
      radius: 0.65,
    ),
    _Orb(
      color: Color(0xFF00E5FF),
      center: Offset(0.2, 0.75),
      amplitude: Offset(0.12, 0.16),
      freq: (2, 3),
      phase: 4.4,
      radius: 0.55,
    ),
  ];

  // シード固定: 再生成されても同じ配置になる。
  static final List<_Particle> _particles = () {
    final r = math.Random(7);
    return List.generate(60, (_) => _Particle(r));
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final t = animation.value * math.pi * 2;
    final shortest = size.shortestSide;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF070B1A), Color(0xFF140A2A), Color(0xFF05050C)],
        ).createShader(rect),
    );

    // 光の玉: 中心から透明へ抜けるradial gradientなので、ぼかしフィルタ無しで
    // 柔らかい光に見える。plusで重なった部分ほど明るくなる。
    for (final orb in _orbs) {
      final c = Offset(
        (orb.center.dx +
                orb.amplitude.dx * math.sin(t * orb.freq.$1 + orb.phase)) *
            size.width,
        (orb.center.dy +
                orb.amplitude.dy * math.cos(t * orb.freq.$2 + orb.phase)) *
            size.height,
      );
      final r =
          orb.radius * shortest * (0.9 + 0.1 * math.sin(t * 3 + orb.phase));
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              orb.color.withValues(alpha: 0.38),
              orb.color.withValues(alpha: 0.12),
              orb.color.withValues(alpha: 0),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    // 光の粒: ゆっくり昇りながら瞬く。
    final dot = Paint()..blendMode = BlendMode.plus;
    for (final p in _particles) {
      final y = (p.y - animation.value * p.rise) % 1.0;
      final twinkle = 0.5 + 0.5 * math.sin(t * p.twinkle + p.phase);
      dot.color = Colors.white.withValues(alpha: 0.15 + 0.6 * twinkle);
      canvas.drawCircle(
        Offset(p.x * size.width, y * size.height),
        p.size * (0.7 + 0.5 * twinkle),
        dot,
      );
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter oldDelegate) =>
      oldDelegate.animation != animation;
}
