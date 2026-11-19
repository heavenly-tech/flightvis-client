import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_localizations.dart';

/// Shared [MaterialApp] configuration for pilot UI (EN + ES).
class PilotAppShell extends StatelessWidget {
  const PilotAppShell({
    super.key,
    required this.home,
    this.locale,
    this.navigatorKey,
  });

  final Widget home;
  final Locale? locale;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'flight_vis',
      locale: locale,
      localeListResolutionCallback: (deviceLocales, supportedLocales) {
        if (locale != null) return locale;
        final devices = deviceLocales;
        if (devices == null || devices.isEmpty) {
          return const Locale('es', 'CL');
        }
        for (final device in devices) {
          if (device.languageCode == 'en') {
            return supportedLocales.firstWhere(
              (l) => l.languageCode == 'en',
              orElse: () => const Locale('en'),
            );
          }
          if (device.languageCode == 'es') {
            return Locale('es', device.countryCode ?? 'CL');
          }
        }
        return const Locale('es', 'CL');
      },
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1B4D89)),
      ),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );
  }
}