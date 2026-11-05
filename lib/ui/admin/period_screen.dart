import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/documents.dart';
import '../../core/format.dart';
import '../../core/csv_text.dart';
import '../../core/report_pdf.dart';
import '../../core/sheet_csv.dart';
import '../../core/theme.dart';
import '../../data/api_client.dart';
import '../../data/app_store.dart';
import '../../domain/models.dart';
import '../glass.dart';
import '../widgets.dart';
import 'payroll_sheets_screen.dart';

/// Paie sur une période libre (semaine, quinzaine…), à titre d'information.
/// Le règlement officiel reste la paie mensuelle validée.
class PeriodScreen extends StatefulWidget {
  const PeriodScreen({super.key});

  @override
  State<PeriodScreen> createState() => _PeriodScreenState();
}

class _PeriodScreenState extends State<PeriodScreen> {
  late DateTime _to = dateOnly(DateTime.now());
  late DateTime _from = _to.subtract(const Duration(days: 6));
  Future<PeriodReport>? _future;

  void _reload() {
    final next = StoreScope.of(context).repo.period(_from, _to);
    setState(() {
      _future = next;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) {
      _future = StoreScope.of(context).repo.period(_from, _to);
      _loadTeams();
    }
  }

  Future<void> _pick(bool isFrom) async {
    final d = await showDatePicker(
        context: context, initialDate: isFrom ? _from : _to, firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (d == null) return;
    if (isFrom) {
      _from = dateOnly(d);
      if (_to.isBefore(_from)) _to = _from;
    } else {
      _to = dateOnly(d);
      if (_to.isBefore(_from)) _from = _to;
    }
    _reload();
  }

  bool _sheetBusy = false;
  List<TeamInfo>? _teams; // null tant que la liste n'est pas chargée : la fiche porte alors sur toutes les équipes
  Set<String> _sel = {};

  bool get _allSelected => _teams != null && _sel.length == _teams!.length;

  /// Équipes envoyées au serveur : null = toutes.
  List<String>? get _teamIds => _teams == null || _allSelected ? null : _sel.toList();

  Future<void> _loadTeams() async {
    try {
      final t = await StoreScope.of(context).repo.teams();
      if (mounted) {
        setState(() {
          _teams = t;
          _sel = {for (final x in t) x.id};
        });
      }
    } on ApiException {
      // Sans la liste, on garde « toutes les équipes ».
    }
  }

  /// Nom de fichier : accents et espaces retirés.
  static String _slug(String s) {
    const from = 'àâäáéèêëíîïóôöúùûüçÀÂÄÁÉÈÊËÍÎÏÓÔÖÚÙÛÜÇ';
    const to = 'aaaaeeeeiiiooouuuucAAAAEEEEIIIOOOUUUUC';
    final b = StringBuffer();
    for (final c in s.split('')) {
      final i = from.indexOf(c);
      b.write(i >= 0 ? to[i] : c);
    }
    return b.toString().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  }

  String get _sheetLabel => _teams == null || _allSelected
      ? 'Fiche de paie (toutes)'
      : 'Fiche de paie (${_sel.length} équipe${_sel.length > 1 ? 's' : ''})';

  /// Fiche de paie (une page par équipe, colonne Signature) sur la période choisie, ouverte à tous les admins.
  Future<void> _sheet({required bool print}) async {
    final repo = StoreScope.of(context).repo;
    final from = _from;
    final to = _to;
    final ids = _teamIds;
    final single = _teams != null && _sel.length == 1 ? _teams!.firstWhere((t) => _sel.contains(t.id)).name : null;
    setState(() => _sheetBusy = true);
    try {
      late final Uint8List bytes;
      final ok = await run(context, () async => bytes = await payrollSheetPdf(await repo.payrollSheet(from, to, teamIds: ids)));
      if (!ok) return;
      final name = 'fiche-de-paie${single == null ? '' : '-${_slug(single)}'}-${dateKey(from)}-${dateKey(to)}';
      if (print) {
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: name);
      } else {
        await sharePdf(bytes, '$name.pdf');
      }
    } finally {
      if (mounted) setState(() => _sheetBusy = false);
    }
  }

  /// Export « Excel » (CSV) de l'aperçu : même contenu que le PDF, s'ouvre directement dans Excel.
  Future<void> _sheetCsv() async {
    final repo = StoreScope.of(context).repo;
    final from = _from;
    final to = _to;
    final ids = _teamIds;
    setState(() => _sheetBusy = true);
    try {
      late final PayrollSheet sheet;
      if (!await run(context, () async => sheet = await repo.payrollSheet(from, to, teamIds: ids))) return;
      final name = 'fiche-de-paie-${dateKey(from)}-${dateKey(to)}.csv';
      await SharePlus.instance.share(ShareParams(
        files: [XFile.fromData(encodeCsv(payrollSheetCsv(sheet)), mimeType: 'text/csv', name: name)],
        fileNameOverrides: [name],
        subject: name,
      ));
    } finally {
      if (mounted) setState(() => _sheetBusy = false);
    }
  }

  /// Établit la fiche : le serveur la fige (photo non modifiable), lui donne un numéro, et le président l'approuvera.
  Future<void> _establish() async {
    final store = StoreScope.of(context);
    final from = _from;
    final to = _to;
    final ids = _teamIds;
    final scope = _teams == null || _allSelected ? 'toutes les équipes' : _teams!.where((t) => _sel.contains(t.id)).map((t) => t.name).join(', ');
    if (!await confirm(
          context,
          'Établir la fiche de paie ?',
          'Période du ${fmtDate(dateKey(from))} au ${fmtDate(dateKey(to))} · $scope.\n\n'
              "La fiche sera figée et numérotée : elle ne changera plus, même si les saisies sont corrigées ensuite. "
              "Le président devra l'approuver. Une journée incomplète ou une fiche déjà établie sur les mêmes jours bloque l'opération.",
          ok: 'Établir',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _sheetBusy = true);
    try {
      ({String id, String number})? made;
      if (!await run(context, () async => made = await store.repo.establishPayrollSheet(from, to, teamIds: ids))) return;
      if (!mounted) return;
      toast(context, "Fiche ${made!.number} établie : en attente d'approbation.");
      await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => StoreScope(store: store, child: PayrollSheetDetailScreen(id: made!.id, number: made!.number))));
    } finally {
      if (mounted) setState(() => _sheetBusy = false);
    }
  }

  /// Un PDF par équipe cochée, partagés ensemble : chaque superviseur reçoit sa propre fiche.
  Future<void> _sheetPerTeam() async {
    final repo = StoreScope.of(context).repo;
    final from = _from;
    final to = _to;
    final teams = _teams!.where((t) => _sel.contains(t.id)).toList();
    setState(() => _sheetBusy = true);
    try {
      final files = <XFile>[];
      final names = <String>[];
      final ok = await run(context, () async {
        for (final t in teams) {
          final bytes = await payrollSheetPdf(await repo.payrollSheet(from, to, teamIds: [t.id]));
          final name = 'fiche-de-paie-${_slug(t.name)}-${dateKey(from)}-${dateKey(to)}.pdf';
          names.add(name);
          files.add(XFile.fromData(bytes, mimeType: 'application/pdf', name: name));
        }
      });
      if (!ok) return;
      await SharePlus.instance.share(ShareParams(files: files, fileNameOverrides: names, subject: 'Fiches de paie ${dateKey(from)} au ${dateKey(to)}'));
    } finally {
      if (mounted) setState(() => _sheetBusy = false);
    }
  }

  Widget _sheetCard() {
    final none = _teams != null && _sel.isEmpty;
    final off = _sheetBusy || none;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Équipes à inclure', style: TextStyle(fontSize: 12, color: textMuted)),
          const SizedBox(height: 6),
          if (_teams == null)
            const Text('Toutes les équipes')
          else
            Wrap(spacing: 8, runSpacing: 4, children: [
              FilterChip(
                label: const Text('Toutes'),
                selected: _allSelected,
                onSelected: (v) => setState(() => _sel = v ? {for (final t in _teams!) t.id} : {}),
              ),
              for (final t in _teams!)
                FilterChip(
                  label: Text(t.name),
                  selected: _sel.contains(t.id),
                  onSelected: (v) => setState(() => v ? _sel.add(t.id) : _sel.remove(t.id)),
                ),
            ]),
          if (none)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Cochez au moins une équipe.', style: TextStyle(fontSize: 12, color: warnColor)),
            ),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: off ? null : () => _sheet(print: false),
              icon: const Icon(Icons.assignment_outlined, size: 18),
              label: Text(_sheetLabel),
            ),
            OutlinedButton.icon(
              onPressed: off ? null : () => _sheet(print: true),
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Imprimer'),
            ),
            OutlinedButton.icon(
              onPressed: off ? null : _sheetCsv,
              icon: const Icon(Icons.table_chart_outlined, size: 18),
              label: const Text('Excel (CSV)'),
            ),
            if (_teams != null && _sel.length > 1)
              OutlinedButton.icon(
                onPressed: off ? null : _sheetPerTeam,
                icon: const Icon(Icons.folder_copy_outlined, size: 18),
                label: const Text('Une fiche par équipe'),
              ),
          ]),
          const Divider(height: 28),
          const Text(
            'Les boutons ci-dessus donnent un aperçu non établi. Pour la paie réelle, établissez la fiche : '
            'elle est figée, numérotée, puis approuvée par le président.',
            style: TextStyle(fontSize: 12, color: textMuted),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: okColor),
              onPressed: off ? null : _establish,
              icon: const Icon(Icons.lock_outline, size: 18),
              label: Text('Établir la fiche${_teams == null || _allSelected ? '' : ' (${_sel.length} équipe${_sel.length > 1 ? 's' : ''})'}'),
            ),
            TextButton.icon(
              onPressed: () {
                final store = StoreScope.of(context);
                Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => StoreScope(
                        store: store,
                        child: Scaffold(
                          appBar: AppBar(flexibleSpace: const GlassBar(child: SizedBox.expand()), title: const Text('Fiches de paie')),
                          body: const PayrollSheetsScreen(),
                        ))));
              },
              icon: const Icon(Icons.assignment_outlined, size: 18),
              label: const Text('Voir les fiches établies'),
            ),
          ]),
        ]),
      ),
    );
  }

  void _preset(int days) {
    _to = dateOnly(DateTime.now());
    _from = _to.subtract(Duration(days: days - 1));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncBody<PeriodReport>(
      future: _future!,
      onRetry: _reload,
      builder: (context, r) => ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(
            child: InkWell(
              onTap: () => _pick(true),
              child: InputDecorator(decoration: const InputDecoration(labelText: 'Du'), child: Text(fmtDate(dateKey(_from)))),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: InkWell(
              onTap: () => _pick(false),
              child: InputDecorator(decoration: const InputDecoration(labelText: 'Au'), child: Text(fmtDate(dateKey(_to)))),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, children: [
          ActionChip(label: const Text('7 derniers jours'), onPressed: () => _preset(7)),
          ActionChip(label: const Text('15 derniers jours'), onPressed: () => _preset(15)),
          ActionChip(label: const Text('30 derniers jours'), onPressed: () => _preset(30)),
        ]),
        const SizedBox(height: 12),
        const InfoBanner(
            icon: Icons.info_outline,
            color: accent,
            text: 'Calcul à titre d\'information : mêmes règles que la paie mensuelle. '
                'Le règlement officiel (validation, verrouillage, paiements) se fait par mois.'),
        const SizedBox(height: 12),
        GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              KeyValue('Briques confectionnées', fmtInt(r.bricks)),
              KeyValue('Payé aux équipes (confection)', fmtMoney(r.cost), bold: true),
              KeyValue('Valeur de vente', fmtMoney(r.sale)),
              KeyValue('Marge', fmtMoney(r.margin), color: okColor),
              if (r.incompleteDays > 0)
                KeyValue('Journées incomplètes (non comptées)', '${r.incompleteDays}', color: warnColor),
            ]),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async => sharePdf(await periodPdf(r), 'paie-${dateKey(_from)}-${dateKey(_to)}.pdf'),
            icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
            label: const Text('Exporter en PDF'),
          ),
        ),
        const SectionTitle('Fiche de paie à signer'),
        _sheetCard(),
        const SectionTitle('Par équipe'),
        GlassCard(
          child: Column(children: [
            if (r.teams.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Aucune production sur la période.')),
            for (final t in r.teams) ListTile(dense: true, title: Text(t.name), trailing: Text(fmtMoney(t.total))),
          ]),
        ),
        const SectionTitle('Par ouvrier'),
        GlassCard(
          child: Column(children: [
            if (r.workers.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Aucun ouvrier payé sur la période.')),
            for (final w in r.workers)
              ListTile(
                dense: true,
                title: Text(w.fullName),
                subtitle: Text('${w.days} jour${w.days > 1 ? 's' : ''}'),
                trailing: Text(fmtMoney(w.total), style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      ]),
    );
  }
}
