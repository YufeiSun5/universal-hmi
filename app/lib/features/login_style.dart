import 'package:flutter/material.dart';

/// Local login palette, adapted from the Zhuanghe HTML login reference.
abstract final class LoginColors {
  static const background = Color(0xff010d19);
  static const field = Color(0xff0b1826);
  static const border = Color(0xff1e6091);
  static const cyan = Color(0xff00ffff);
  static const title = Color(0xff48acff);
  static const muted = Color(0xffb8cbdc);
  static const warning = Color(0xffffb74d);
}

ThemeData loginTheme(ThemeData base) {
  const border = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(2)),
    borderSide: BorderSide(color: LoginColors.border),
  );
  return base.copyWith(
    colorScheme: const ColorScheme.dark(
      primary: LoginColors.cyan,
      onPrimary: LoginColors.background,
      surface: LoginColors.field,
      onSurface: Colors.white,
      onSurfaceVariant: LoginColors.muted,
      error: LoginColors.warning,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: Colors.white,
      displayColor: Colors.white,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: LoginColors.cyan,
      selectionColor: Color(0x5548acff),
      selectionHandleColor: LoginColors.cyan,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: LoginColors.field,
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      hintStyle: TextStyle(color: Color(0xff7393b0), fontSize: 14),
      helperStyle: TextStyle(color: LoginColors.muted, fontSize: 12),
      prefixIconColor: LoginColors.title,
      suffixIconColor: LoginColors.title,
      border: border,
      enabledBorder: border,
      disabledBorder: border,
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(2)),
        borderSide: BorderSide(color: LoginColors.cyan),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: LoginColors.title,
        minimumSize: const Size(44, 44),
        maximumSize: const Size(48, 48),
        padding: const EdgeInsets.all(10),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: LoginColors.title,
        padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 8),
        textStyle: base.textTheme.labelLarge?.copyWith(fontSize: 13),
      ),
    ),
  );
}

class LoginBackdrop extends StatelessWidget {
  const LoginBackdrop({super.key, required this.child, this.mobile = false});
  final Widget child;
  final bool mobile;

  @override
  Widget build(BuildContext context) => mobile
      ? MobileLoginBackdrop(child: child)
      : Theme(
          data: loginTheme(Theme.of(context)),
          child: Scaffold(
            backgroundColor: LoginColors.background,
            body: LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth <= 600;
                final horizontal = narrow
                    ? 16.0
                    : constraints.maxWidth <= 900
                    ? 32.0
                    : constraints.maxWidth * .10;
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ExcludeSemantics(
                      child: Image.asset(
                        'assets/login/coastal-heating.png',
                        fit: BoxFit.cover,
                        alignment: narrow
                            ? Alignment.centerRight
                            : Alignment.center,
                        errorBuilder: (_, error, stackTrace) =>
                            const ColoredBox(color: LoginColors.background),
                      ),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Color(0x1f010d19),
                            Color(0x73010d19),
                            Color(0xb8010d19),
                          ],
                          stops: [0, .55, 1],
                        ),
                      ),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x66010d19),
                            Color(0x00010d19),
                            Color(0x94010d19),
                          ],
                          stops: [0, .45, 1],
                        ),
                      ),
                    ),
                    SafeArea(
                      child: LayoutBuilder(
                        builder: (context, viewport) => SingleChildScrollView(
                          padding: EdgeInsets.symmetric(
                            horizontal: horizontal,
                            vertical: narrow ? 20 : 28,
                          ),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight:
                                  (viewport.maxHeight - (narrow ? 40 : 56))
                                      .clamp(0, double.infinity),
                            ),
                            child: Align(
                              alignment: narrow
                                  ? Alignment.center
                                  : Alignment.centerRight,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 440,
                                ),
                                child: LoginCard(child: child),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
}

class MobileLoginBackdrop extends StatelessWidget {
  const MobileLoginBackdrop({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final base = loginTheme(Theme.of(context));
    const border = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(14)),
      borderSide: BorderSide(color: Color(0xff2a4054)),
    );
    return Theme(
      data: base.copyWith(
        visualDensity: VisualDensity.standard,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          fillColor: const Color(0xff132638),
          constraints: const BoxConstraints(minHeight: 52),
          border: border,
          enabledBorder: border,
          disabledBorder: border,
          focusedBorder: border.copyWith(
            borderSide: const BorderSide(color: Color(0xff5ca9f4), width: 1.5),
          ),
          prefixIconColor: const Color(0xff9bb9d2),
          suffixIconColor: const Color(0xff9bb9d2),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            minimumSize: const Size(44, 44),
            maximumSize: Size.infinite,
            foregroundColor: const Color(0xff8bc6ff),
            textStyle: base.textTheme.labelLarge?.copyWith(fontSize: 13),
          ),
        ),
      ),
      child: Scaffold(
        backgroundColor: const Color(0xff0c1723),
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [Color(0xff19354d), Color(0xff0c1723), Color(0xff0c1723)],
              stops: [0, .5, 1],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, viewport) => SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 28,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (viewport.maxHeight - 56).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 38,
                                height: 38,
                                decoration: BoxDecoration(
                                  color: const Color(0xff244765),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Icon(
                                  Icons.hub_outlined,
                                  color: Color(0xff9dd8ff),
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'UNIVERSAL HMI',
                                  style: TextStyle(
                                    color: Color(0xffc1d9eb),
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    letterSpacing: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 36),
                          child,
                        ],
                      ),
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

class LoginCard extends StatelessWidget {
  const LoginCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xf0183452), Color(0xf5102133)],
      ),
      border: Border.all(color: const Color(0xa600ffff)),
      borderRadius: BorderRadius.circular(2),
      boxShadow: const [
        BoxShadow(
          color: Color(0xd1010d19),
          blurRadius: 54,
          offset: Offset(0, 20),
        ),
        BoxShadow(color: Color(0x2208b9ff), blurRadius: 24),
      ],
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 2,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [LoginColors.cyan, LoginColors.title, LoginColors.cyan],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            MediaQuery.sizeOf(context).width <= 600 ? 24 : 34,
            32,
            MediaQuery.sizeOf(context).width <= 600 ? 24 : 34,
            26,
          ),
          child: child,
        ),
      ],
    ),
  );
}
