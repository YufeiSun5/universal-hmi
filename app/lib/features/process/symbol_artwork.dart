import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'catalog.dart';

/// The same reusable material in the palette, drag preview and process scene.
class ProcessSymbolArtwork extends StatelessWidget {
  const ProcessSymbolArtwork({
    super.key,
    required this.symbol,
    this.fit = BoxFit.contain,
    this.colorFilter,
  });
  final ProcessSymbol symbol;
  final BoxFit fit;
  final ColorFilter? colorFilter;
  @override
  Widget build(BuildContext context) => symbol.raster
      ? Image.asset(symbol.path, fit: fit, gaplessPlayback: true)
      : SvgPicture.asset(symbol.path, fit: fit, colorFilter: colorFilter);
}
