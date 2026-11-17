import 'package:flutter/material.dart';

import '../services/app_repository.dart';

class HiddenSettingsScreen extends StatefulWidget {
  const HiddenSettingsScreen({super.key, required this.repo});

  final AppRepository repo;

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
    await widget.repo.prefs.setBaseUrl(_url.text);
    widget.repo.refreshBaseUrl();
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Server URL saved')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server settings')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'API base URL',
                border: OutlineInputBorder(),
                helperText: 'Build default can be overridden here. No trailing slash.',
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
      ),
    );
  }
}