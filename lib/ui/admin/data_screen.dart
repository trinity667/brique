import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/csv_text.dart';
import '../../core/theme.dart';
import '../../data/app_store.dart';
import '../../domain/models.dart';
import '../glass.dart';
import '../widgets.dart';

/// Données : import en masse des ouvriers (fichier CSV ou tableau collé depuis Excel) et sauvegarde complète.
class DataScreen extends StatefulWidget {
  const DataScreen({super.key});

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  final _text = TextEditingController();
  ImportResult? _result;
  bool _busy = false;
  String? _fileName; // fichier choisi (affiché au-dessus de la zone de texte)

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _import(bool dryRun) async {
    final store = StoreScope.of(context);
    setState(() => _busy = true);
    ImportResult? r;
    final ok = await run(context, () async {
      r = await store.repo.importWorkers(_text.text, dryRun: dryRun);
    }, success: dryRun ? null : 'Import terminé.');
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) {
        _result = r;
        if (!dryRun) {
          _text.clear();
          _fileName = null;
        }
      }
    });
  }

  /// Lit un fichier CSV (ou texte) exporté d'Excel, le met dans la zone de texte et lance la vérification :
  /// rien n'est écrit tant qu'on n'a pas cliqué sur « Importer ».
  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: 'Choisir le fichier des ouvriers',
      type: FileType.custom,
      allowedExtensions: const ['csv', 'txt', 'tsv'],
      withData: true,
    );
    final file = picked?.files.single;
    if (file == null || !mounted) return;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      toast(context, 'Fichier vide ou illisible.', error: true);
      return;
    }
    setState(() {
      _text.text = decodeCsvBytes(bytes);
      _fileName = file.name;
      _result = null;
    });
    await _import(true);
  }

  Future<void> _backup() async {
    final store = StoreScope.of(context);
    setState(() => _busy = true);
    final ok = await run(context, () async {
      final json = await store.repo.backupJson();
      final name = 'sauvegarde-${DateTime.now().toIso8601String().substring(0, 10)}.json';
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(utf8.encode(json), mimeType: 'application/json', name: name)],
        fileNameOverrides: [name],
        subject: 'Sauvegarde Briques & Paie',
      ));
    });
    if (mounted) setState(() => _busy = false);
    if (ok && mounted) toast(context, 'Sauvegarde exportée.');
  }

  static Color _statusColor(String s) => switch (s) {
        'ok' => okColor,
        'duplicate' => warnColor,
        _ => errColor,
      };

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const SectionTitle('Importer des ouvriers'),
      GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
                'Choisissez un fichier CSV (dans Excel : Fichier > Enregistrer sous > CSV), ou collez les lignes '
                'ci-dessous. Si la première ligne est un en-tête (Nom, Téléphone, Village, N° CNIB, Opérateur, '
                'Numéro mobile, Équipe), les colonnes sont reconnues dans n\'importe quel ordre et les autres sont '
                'ignorées. Sans en-tête, l\'ordre est : Nom, Téléphone, Village, Opérateur (orange, moov, telecel, '
                'autre), Numéro mobile money, Équipe, N° CNIB. Seul le nom est obligatoire.',
                style: TextStyle(fontSize: 13, color: textMuted)),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choisir un fichier CSV'),
              ),
              if (_fileName != null) Text(_fileName!, style: const TextStyle(fontSize: 13, color: textMuted)),
            ]),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              onChanged: (_) => setState(() {
                _result = null;
                _fileName = null;
              }),
              minLines: 6,
              maxLines: 12,
              decoration: const InputDecoration(
                  hintText: 'Kaboré Ali\t70 11 22 33\tKoudougou\torange\t70 11 22 33\tÉquipe 1', alignLabelWithHint: true),
            ),
            const SizedBox(height: 12),
            Wrap(spacing: 12, runSpacing: 8, children: [
              OutlinedButton.icon(
                onPressed: _busy || _text.text.trim().isEmpty ? null : () => _import(true),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Vérifier'),
              ),
              FilledButton.icon(
                onPressed: _busy || r == null || !r.dryRun || r.ok == 0 ? null : () => _import(false),
                icon: const Icon(Icons.upload_file),
                label: Text(r != null && r.dryRun && r.ok > 0 ? 'Importer ${r.ok} ouvrier${r.ok > 1 ? 's' : ''}' : 'Importer'),
              ),
            ]),
          ]),
        ),
      ),
      if (r != null) ...[
        const SizedBox(height: 12),
        InfoBanner(
          icon: r.dryRun ? Icons.fact_check_outlined : Icons.check_circle,
          color: r.error > 0 ? warnColor : okColor,
          text: r.dryRun
              ? '${r.ok} prêt(s) à importer · ${r.duplicate} déjà présent(s) · ${r.error} erreur(s). Rien n\'est encore enregistré.'
              : '${r.imported} ouvrier(s) importé(s) · ${r.duplicate} ignoré(s) (doublons) · ${r.error} erreur(s).',
        ),
        const SizedBox(height: 8),
        GlassCard(
          child: Column(children: [
            for (final row in r.rows)
              ListTile(
                dense: true,
                leading: Icon(
                    row.status == 'ok' ? Icons.check_circle_outline : row.status == 'duplicate' ? Icons.copy_all : Icons.error_outline,
                    color: _statusColor(row.status)),
                title: Text(row.name.isEmpty ? '(sans nom)' : row.name),
                subtitle: Text('Ligne ${row.line}${row.message.isEmpty ? '' : ' · ${row.message}'}'),
              ),
          ]),
        ),
      ],
      const SectionTitle('Sauvegarde'),
      GlassCard(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
                'Exporte toutes les données (équipes, ouvriers, saisies, paies, paiements, avances, journal) '
                'dans un fichier. Les codes PIN et les signatures de visage n\'y figurent jamais. '
                'Conservez ce fichier en lieu sûr : il contient des informations personnelles et des montants.',
                style: TextStyle(fontSize: 13, color: textMuted)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _backup,
              icon: const Icon(Icons.download),
              label: const Text('Exporter la sauvegarde'),
            ),
          ]),
        ),
      ),
    ]);
  }
}
