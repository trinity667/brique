import 'package:flutter/material.dart';

import '../core/theme.dart';

// Composants de surface de l'application. Les noms (« Glass… ») datent de la première charte
// et sont gardés pour ne pas toucher chaque écran ; le rendu est désormais clair et sobre.

/// Fond de page commun à toutes les routes (MaterialApp.builder) : gris-vert très clair,
/// avec un léger reflet vert et or dans les angles.
class AuroraBackground extends StatelessWidget {
  final Widget child;
  const AuroraBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(fit: StackFit.expand, children: [
      const ColoredBox(color: inkBase),
      const Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-1.1, -1.2),
              radius: 1.1,
              colors: [Color(0x141E6B3A), Color(0x001E6B3A)],
            ),
          ),
        ),
      ),
      const Positioned.fill(
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(1.2, 1.2),
              radius: 0.9,
              colors: [Color(0x12C9A227), Color(0x00C9A227)],
            ),
          ),
        ),
      ),
      child,
    ]);
  }
}

/// Carte blanche : bord fin, ombre légère. `tint` colore discrètement le fond (tuiles KPI).
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final Gradient? tint;
  final double blur; // conservé pour compatibilité, sans effet

  const GlassCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = 14,
    this.tint,
    this.blur = 0,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius > 16 ? 16 : radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: panelSolid,
        borderRadius: r,
        border: Border.all(color: lineColor),
        boxShadow: const [BoxShadow(color: Color(0x0F17251C), blurRadius: 12, offset: Offset(0, 3))],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: tint),
          child: Material(
            type: MaterialType.transparency,
            child: padding == null ? child : Padding(padding: padding!, child: child),
          ),
        ),
      ),
    );
  }
}

/// Bouton principal vert, plein.
class GradientButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  final Gradient gradient;

  const GradientButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
    this.gradient = brandGradient,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(12),
          boxShadow: enabled
              ? [BoxShadow(color: accent.withValues(alpha: 0.22), blurRadius: 12, offset: const Offset(0, 4))]
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onPressed,
            child: SizedBox(
              height: 52,
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                if (icon != null) ...[Icon(icon, color: Colors.white), const SizedBox(width: 10)],
                Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Barre (AppBar ou navigation du bas) : blanche avec un filet.
class GlassBar extends StatelessWidget {
  final Widget child;
  const GlassBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          color: panelSolid,
          border: Border(bottom: BorderSide(color: lineColor), top: BorderSide(color: lineColor)),
        ),
        child: child,
      );
}

/// Texte avec dégradé de marque.
class GradientText extends StatelessWidget {
  final String text;
  final TextStyle style;
  final Gradient gradient;
  const GradientText(this.text, {super.key, required this.style, this.gradient = brandGradient});

  @override
  Widget build(BuildContext context) => ShaderMask(
        shaderCallback: (r) => gradient.createShader(Rect.fromLTWH(0, 0, r.width, r.height)),
        blendMode: BlendMode.srcIn,
        child: Text(text, style: style.copyWith(color: Colors.white)),
      );
}
