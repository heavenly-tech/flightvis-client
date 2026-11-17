import 'package:flutter/material.dart';

import '../dev/dev_tools_gate.dart';
import '../l10n/pilot_l10n.dart';
import '../services/app_repository.dart';
import '../widgets/language_picker_sheet.dart';

class HiddenSettingsScreen extends StatefulWidget {
  const HiddenSettingsScreen({
    super.key,
    required this.repo,
    this.onLocaleChanged,
  });

  final AppRepository repo;
  final VoidCallback? onLocaleChanged;

  @override
  State<HiddenSettingsScreen> createState() => _HiddenSettingsScreenState();
}

class _HiddenSettingsScreenState extends State<HiddenSettingsScreen> {
  late final TextEditingController _url;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.repo.prefs.baseUrl());
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final l10n = context.pilotL10n;
    await widget.repo.prefs.setBaseUrl(_url.text);
    widget.repo.refreshBaseUrl();
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.hiddenServerUrlSaved)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!hiddenServerSettingsEnabled) {
      return const SizedBox.shrink();
    }
    final l10n = context.pilotL10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.hiddenServerSettingsTitle)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _url,
              decoration: InputDecoration(
                labelText: l10n.hiddenApiBaseUrlLabel,
                border: const OutlineInputBorder(),
                helperText: l10n.hiddenApiBaseUrlHelper,
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.language),
              title: Text(l10n.pilotLanguageTitle),
              subtitle: Text(_languageSubtitle(l10n)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showLanguagePickerSheet(
                context: context,
                repo: widget.repo,
                onChanged: () {
                  widget.onLocaleChanged?.call();
                  setState(() {});
                },
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: Text(l10n.saveButton)),
          ],
        ),
      ),
    );
  }

  String _languageSubtitle(dynamic l10n) {
    return switch (widget.repo.localePrefs.languageOverride()) {
      'en' => l10n.pilotLanguageEnglish,
      'es' => l10n.pilotLanguageSpanish,
      _ => l10n.pilotLanguageSystem,
    };
  }
}