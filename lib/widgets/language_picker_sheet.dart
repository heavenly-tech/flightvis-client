import 'package:flutter/material.dart';

import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';

/// Bottom sheet to pick app language (persisted override).
Future<void> showLanguagePickerSheet({
  required BuildContext context,
  required AppRepository repo,
  required VoidCallback onChanged,
}) {
  final l10n = context.pilotL10n;
  final current = repo.localePrefs.languageOverride();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(l10n.pilotLanguageTitle, style: Theme.of(ctx).textTheme.titleLarge),
              ),
            ),
            RadioListTile<String?>(
              title: Text(l10n.pilotLanguageSystem),
              value: null,
              groupValue: current,
              onChanged: (v) async {
                await repo.localePrefs.setLanguageOverride(null);
                if (ctx.mounted) Navigator.pop(ctx);
                onChanged();
              },
            ),
            RadioListTile<String?>(
              title: Text(l10n.pilotLanguageSpanish),
              value: 'es',
              groupValue: current,
              onChanged: (v) async {
                await repo.localePrefs.setLanguageOverride('es');
                if (ctx.mounted) Navigator.pop(ctx);
                onChanged();
              },
            ),
            RadioListTile<String?>(
              title: Text(l10n.pilotLanguageEnglish),
              value: 'en',
              groupValue: current,
              onChanged: (v) async {
                await repo.localePrefs.setLanguageOverride('en');
                if (ctx.mounted) Navigator.pop(ctx);
                onChanged();
              },
            ),
          ],
        ),
      );
    },
  );
}