import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/documents.dart';
import '../../core/format.dart';
import '../../core/report_pdf.dart';
import '../../core/theme.dart';
import '../../data/app_store.dart';
import '../../domain/models.dart';
import '../glass.dart';
import '../widgets.dart';

/// Rapports officiels, RÉSERVÉS AU PRÉSIDENT (la page n'apparaît que pour lui et le serveur
/// refuse toute autre personne) : production (modèle du rapport BTC), paie globale des équipes,
/// présences. Chaque rapport s'imprime, se télécharge en PDF ou s'exporte pour Excel (CSV).
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

enum _Kind { production, payroll, attendance }

class _ReportsScreenState extends State<ReportsScreen> {
  _Kind _kind = _Kind.production;
  late DateTime _to = dateOnly(DateTime.now());
  late DateTime _from = DateTime(_to.year, _to.month, 1);
  String? _teamId;
  String? _clientId;
  List<TeamInfo> _teams = const [];
  List<ClientInfo> _clients = const [];
  Future<Object>? _future;
  bool _busy = false;

  /// Cases cochées du rapport de présence (« équipe|ouvrier »), reprises dans le PDF.
  final Set<String> _checked = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) {
      final repo = StoreScope.of(context).repo;
      _future = _fetch();
      repo.teams().then((t) {
        if (mounted) setState(() => _teams = t);
      }, onError: (_) {});
      // Client par défaut : le premier client actif (ses références s'impriment sous l'en-tête).
      repo.clients().then((c) {
        if (!mounted) return;
        setState(() {
          _clients = c.where((x) => x.active).toList();
          _clientId ??= _clients.firstOrNull?.id;
        });
        if (_clientId != null) _reload();
      }, onError: (_) {});
    }
  }

  Future<Object> _fetch() {
    final repo = StoreScope.of(context).repo;
    return switch (_kind) {
      _Kind.production => repo.productionReport(_from, _to, teamId: _teamId, clientId: _clientId),
      _Kind.payroll => repo.teamPayrollReport(_from, _to, teamId: _teamId, clientId: _clientId),
      _Kind.attendance => repo.attendanceReport(_from, _to, teamId: _teamId, clientId: _clientId),
    };
  }

  Future<void> _editSettings() async {
    final store = StoreScope.of(context);
    ReportSettings? current;
    if (!await run(context, () async => current = await store.repo.reportSettings())) return;
    if (!mounted) return;
    final next = await showDialog<ReportSettings>(context: context, builder: (_) => _SettingsDialog(current!));
    if (next == null || !mounted) return;
    if (await run(context, () => store.repo.saveReportSettings(next), success: 'Réglages des rapports enregistrés.')) {
      _reload();
    }
  }

  void _reload() => setState(() => _future = _fetch());

  Future<void> _pick(bool isFrom) async {
    final d = await showDatePicker(
      context: context,
      initialDate: isFrom ? _from : _to,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
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

  void _preset(DateTime from, DateTime to) {
    _from = from;
    _to = to;
    _reload();
  }

  String get _slug => switch (_kind) {
    _Kind.production => 'rapport-production',
    _Kind.payroll => 'paie-globale-equipes',
    _Kind.attendance => 'rapport-presence',
  };
  String get _fileBase => '$_slug-${dateKey(_from)}-au-${dateKey(_to)}';

  Future<Uint8List> _pdf(Object r) => switch (r) {
    ProductionReport r => productionPdf(r),
    TeamPayrollReport r => teamPayrollPdf(r),
    AttendanceReport r => attendancePdf(r, checked: _checked),
    _ => throw StateError('rapport inconnu'),
  };

  Future<void> _act(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) toast(context, 'Opération impossible : $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _print(Object r) => _act(() async {
    final bytes = await _pdf(r);
    await Printing.layoutPdf(onLayout: (_) async => bytes, name: _fileBase);
  });

  Future<void> _download(Object r) => _act(() async => sharePdf(await _pdf(r), '$_fileBase.pdf'));

  Future<void> _csv(Object r) => _act(() async {
    final name = '$_fileBase.csv';
    // BOM + « ; » : s'ouvre directement dans Excel en français, accents compris.
    final data = Uint8List.fromList(utf8.encode('﻿${_toCsv(r)}'));
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(data, mimeType: 'text/csv', name: name)],
        fileNameOverrides: [name],
        subject: name,
      ),
    );
  });

  String _toCsv(Object r) {
    String row(List<Object> cells) => cells.map((c) => '"${c.toString().replaceAll('"', '""')}"').join(';');
    String money(Money m) => m.value.replaceAll('.', ',');
    final lines = <String>[];
    switch (r) {
      case ProductionReport r:
        lines.add(row(['Date', 'Poste', r.head.settings.productLabel, r.head.settings.cementLabel]));
        for (final x in r.rows) {
          lines.add(row([fmtDate(x.date), shiftLabel(x.shift), x.bricks, x.cementBags]));
        }
        lines.add(row(['TOTAL', '', r.totalBricks, r.totalCement]));
        lines.add('');
        lines.add(row(['Nombre BTC', 'Prix unitaire (FCFA)', 'Montant à payer (FCFA)']));
        lines.add(row([r.totalBricks, r.unitPrice ?? 'Variable', money(r.amount)]));
      case TeamPayrollReport r:
        lines.add(
          row([
            'Date',
            for (final t in r.teams) ...['${t.name} - briques', '${t.name} - somme (FCFA)'],
            'Total briques',
            'Total somme (FCFA)',
          ]),
        );
        for (final d in r.days) {
          lines.add(
            row([
              fmtDate(d.date),
              for (final c in d.cells) ...[c.bricks, money(c.amount)],
              d.bricks,
              money(d.amount),
            ]),
          );
        }
        lines.add(
          row([
            'TOTAL',
            for (final t in r.teams) ...[t.bricks, money(t.amount)],
            r.totalBricks,
            money(r.totalAmount),
          ]),
        );
      case AttendanceReport r:
        lines.add(row(['Équipe', 'Poste', 'Nom et prénoms', 'Nombre de fois présent', 'Absences', 'Coché']));
        for (final t in r.teams) {
          for (final m in t.members) {
            lines.add(
              row([
                t.name,
                shiftLabel(t.shift),
                '${m.fullName}${m.substitute ? ' (remplaçant)' : ''}',
                m.present,
                m.absent,
                _checked.contains('${t.teamId}|${m.workerId}') ? 'X' : '',
              ]),
            );
          }
        }
    }
    return lines.join('\r\n');
  }

  @override
  Widget build(BuildContext context) {
    final now = dateOnly(DateTime.now());
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SegmentedButton<_Kind>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _Kind.production, icon: Icon(Icons.factory_outlined), label: Text('Production')),
            ButtonSegment(value: _Kind.payroll, icon: Icon(Icons.request_quote_outlined), label: Text('Paie globale')),
            ButtonSegment(value: _Kind.attendance, icon: Icon(Icons.how_to_reg_outlined), label: Text('Présences')),
          ],
          selected: {_kind},
          onSelectionChanged: (s) {
            _kind = s.first;
            _reload();
          },
        ),
        const SizedBox(height: 14),
        GlassCard(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _dateField('Du', _from, () => _pick(true)),
                  _dateField('Au', _to, () => _pick(false)),
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String?>(
                      initialValue: _teamId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Équipe', prefixIcon: Icon(Icons.groups_outlined)),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Toutes les équipes')),
                        for (final t in _teams) DropdownMenuItem(value: t.id, child: Text(t.name)),
                      ],
                      onChanged: (v) {
                        _teamId = v;
                        _reload();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 280,
                    child: DropdownButtonFormField<String?>(
                      key: ValueKey('client-${_clients.length}-$_clientId'),
                      initialValue: _clientId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Client (références en en-tête)',
                        prefixIcon: Icon(Icons.business_outlined),
                      ),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Aucun client')),
                        for (final c in _clients) DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) {
                        _clientId = v;
                        _reload();
                      },
                    ),
                  ),
                ],
              ),
              if (_clients.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Aucun client enregistré : ajoutez-le dans Factures → Clients (nom, statut, RCCM, IFU, capital, siège).',
                    style: TextStyle(fontSize: 12, color: textMuted),
                  ),
                ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  ActionChip(
                    label: const Text('Ce mois-ci'),
                    onPressed: () => _preset(DateTime(now.year, now.month, 1), now),
                  ),
                  ActionChip(
                    label: const Text('Mois dernier'),
                    onPressed: () => _preset(DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 0)),
                  ),
                  ActionChip(
                    label: const Text('1re quinzaine'),
                    onPressed: () => _preset(DateTime(now.year, now.month, 1), DateTime(now.year, now.month, 15)),
                  ),
                  ActionChip(
                    label: const Text('7 derniers jours'),
                    onPressed: () => _preset(now.subtract(const Duration(days: 6)), now),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AsyncBody<Object>(
          future: _future!,
          onRetry: _reload,
          builder: (context, r) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _actions(r),
              const SizedBox(height: 12),
              switch (r) {
                ProductionReport r => _production(r),
                TeamPayrollReport r => _payroll(r),
                AttendanceReport r => _attendance(r),
                _ => const SizedBox(),
              },
            ],
          ),
        ),
      ],
    );
  }

  Widget _dateField(String label, DateTime d, VoidCallback onTap) => SizedBox(
    width: 170,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.event_outlined)),
        child: Text(fmtDate(dateKey(d))),
      ),
    ),
  );

  Widget _actions(Object r) => Wrap(
    spacing: 10,
    runSpacing: 8,
    alignment: WrapAlignment.end,
    children: [
      TextButton.icon(
        onPressed: _busy ? null : _editSettings,
        icon: const Icon(Icons.tune),
        label: const Text('Signataires et libellés'),
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.all(8),
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
        onPressed: _busy ? null : () => _print(r),
        icon: const Icon(Icons.print_outlined),
        label: const Text('Imprimer'),
      ),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
        onPressed: _busy ? null : () => _download(r),
        icon: const Icon(Icons.picture_as_pdf_outlined),
        label: const Text('Télécharger PDF'),
      ),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
        onPressed: _busy ? null : () => _csv(r),
        icon: const Icon(Icons.table_view_outlined),
        label: const Text('Excel (CSV)'),
      ),
    ],
  );

  // ───── Aperçus à l'écran (mêmes colonnes que les documents) ─────

  Widget _table(List<String> headers, List<List<String>> rows, {List<String>? total, Map<int, TextAlign>? align}) {
    TextAlign a(int i) => align?[i] ?? (i == 0 ? TextAlign.left : TextAlign.right);
    Widget cell(String t, int i, {bool bold = false, Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Text(
        t,
        textAlign: a(i),
        style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color, fontSize: 13.5),
      ),
    );
    return GlassCard(
      child: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: box.maxWidth < 560 ? 560 : box.maxWidth),
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
              border: const TableBorder(horizontalInside: BorderSide(color: lineColor)),
              children: [
                TableRow(
                  decoration: const BoxDecoration(color: accentDeep),
                  children: [for (final (i, h) in headers.indexed) cell(h, i, bold: true, color: Colors.white)],
                ),
                for (final (n, r) in rows.indexed)
                  TableRow(
                    decoration: BoxDecoration(color: n.isOdd ? surfaceAlt : null),
                    children: [for (final (i, c) in r.indexed) cell(c, i)],
                  ),
                if (total != null)
                  TableRow(
                    decoration: BoxDecoration(color: gold.withValues(alpha: 0.18)),
                    children: [for (final (i, c) in total.indexed) cell(c, i, bold: true)],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kpis(List<(String, String, IconData)> items) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth >= 700 ? (box.maxWidth - 24) / 3 : box.maxWidth;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final (label, value, icon) in items)
            SizedBox(
              width: w,
              child: StatTile(label: label, value: value, icon: icon),
            ),
        ],
      );
    },
  );

  Widget _production(ProductionReport r) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _kpis([
        (r.head.settings.productLabel, fmtInt(r.totalBricks), Icons.view_in_ar_rounded),
        (r.head.settings.cementLabel, fmtInt(r.totalCement), Icons.inventory_2_outlined),
        ('Montant à payer', fmtMoney(r.amount), Icons.payments_outlined),
      ]),
      if (r.missingPrice) ...[
        const SizedBox(height: 10),
        const InfoBanner(
          icon: Icons.warning_amber_rounded,
          color: warnColor,
          text: 'Prix de vente manquant pour certaines dates : non comptées dans le montant.',
        ),
      ],
      const SectionTitle('Détail par jour et par poste'),
      _table(
        ['Date / poste', r.head.settings.productLabel, r.head.settings.cementLabel],
        [
          for (final x in r.rows) ['${fmtDate(x.date)} ${shiftLabel(x.shift)}', fmtInt(x.bricks), fmtInt(x.cementBags)],
        ],
        total: ['TOTAL', fmtInt(r.totalBricks), fmtInt(r.totalCement)],
      ),
      const SizedBox(height: 12),
      _table(
        ['Nombre BTC', 'Prix unitaire (FCFA)', 'Montant à payer (FCFA)'],
        [
          [
            fmtInt(r.totalBricks),
            r.unitPrice == null ? 'Variable' : fmtInt(r.unitPrice!),
            fmtMoney(r.amount, unit: false),
          ],
        ],
        align: const {0: TextAlign.center, 1: TextAlign.center, 2: TextAlign.center},
      ),
      const SectionTitle('Signatures (en bas du rapport imprimé)'),
      if (r.head.settings.signatories.isEmpty)
        const InfoBanner(
          icon: Icons.draw_outlined,
          color: warnColor,
          text: 'Aucun signataire : renseignez les postes et les noms avec « Signataires et libellés ».',
        )
      else
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final s in r.head.settings.signatories)
              SizedBox(
                width: 250,
                child: GlassCard(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                      if (s.company.isNotEmpty) Text(s.company, style: const TextStyle(color: textMuted)),
                      const SizedBox(height: 6),
                      for (final n in s.names) Text('• $n'),
                    ],
                  ),
                ),
              ),
          ],
        ),
    ],
  );

  Widget _payroll(TeamPayrollReport r) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _kpis([
        ('Briques confectionnées', fmtInt(r.totalBricks), Icons.view_in_ar_rounded),
        ('Somme due aux équipes', fmtMoney(r.totalAmount), Icons.payments_outlined),
        ('Prix de confection', r.unitPrice == null ? 'Variable' : fmtFcfa(r.unitPrice!), Icons.sell_outlined),
      ]),
      SectionTitle('Paie par date · ${r.teams.length} équipe(s) enregistrée(s)'),
      if (r.days.isEmpty)
        const GlassCard(padding: EdgeInsets.all(16), child: Text('Aucune production saisie sur la période.')),
      // Toutes les équipes enregistrées en colonnes : briques et somme de chacune, puis le total du jour.
      _table(
        [
          'Date',
          for (final t in r.teams) ...['${t.name} · briques', '${t.name} · somme'],
          'Total briques',
          'Total somme (FCFA)',
        ],
        [
          for (final d in r.days)
            [
              fmtDate(d.date),
              for (final c in d.cells) ...[
                '${fmtInt(c.bricks)}${c.incomplete ? ' *' : ''}',
                fmtMoney(c.amount, unit: false),
              ],
              fmtInt(d.bricks),
              fmtMoney(d.amount, unit: false),
            ],
        ],
        total: [
          'TOTAL',
          for (final t in r.teams) ...[fmtInt(t.bricks), fmtMoney(t.amount, unit: false)],
          fmtInt(r.totalBricks),
          fmtMoney(r.totalAmount, unit: false),
        ],
      ),
      if (r.days.any((d) => d.cells.any((c) => c.incomplete)))
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            '* Journée à régulariser (présences non saisies ou aucun présent) avant la paie officielle.',
            style: TextStyle(fontSize: 12, color: textMuted),
          ),
        ),
    ],
  );

  Widget _attendance(AttendanceReport r) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const InfoBanner(
        icon: Icons.check_box_outlined,
        color: accent,
        text:
            'Cochez les cases à l\'écran : elles sont reprises dans le PDF imprimé. Les cases non cochées restent vides pour cocher à la main.',
      ),
      if (r.teams.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Aucune équipe.')),
      for (final t in r.teams) ...[
        SectionTitle(
          t.name,
          trailing: Text(
            'Poste de ${t.shift} · ${t.days} journée(s)',
            style: const TextStyle(color: textMuted, fontSize: 13),
          ),
        ),
        GlassCard(
          child: Column(
            children: [
              Container(
                color: accentDeep,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: const Row(
                  children: [
                    SizedBox(
                      width: 34,
                      child: Text(
                        'N°',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        'Nom et prénoms',
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: Text(
                        'Présent',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                    SizedBox(
                      width: 80,
                      child: Text(
                        'Absent',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        'Cocher',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              ),
              if (t.members.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Aucun membre.')),
              for (final (i, m) in t.members.indexed)
                Container(
                  color: i.isOdd ? surfaceAlt : null,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 34,
                        child: Text('${i + 1}', style: const TextStyle(color: textMuted)),
                      ),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: m.fullName),
                              if (m.substitute)
                                const TextSpan(
                                  text: '  remplaçant',
                                  style: TextStyle(color: textMuted, fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 90,
                        child: Text(
                          '${m.present}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.w800, color: okColor),
                        ),
                      ),
                      SizedBox(
                        width: 80,
                        child: Text(
                          '${m.absent}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: textMuted),
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        child: Checkbox(
                          value: _checked.contains('${t.teamId}|${m.workerId}'),
                          onChanged: (v) => setState(() {
                            final k = '${t.teamId}|${m.workerId}';
                            v == true ? _checked.add(k) : _checked.remove(k);
                          }),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    ],
  );
}

/// Réglages des rapports : libellés des colonnes et signataires (poste, structure, noms).
/// Un nom par ligne ; plusieurs noms = une case à cocher devant chacun sur le document.
class _SettingsDialog extends StatefulWidget {
  final ReportSettings initial;
  const _SettingsDialog(this.initial);

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SignatoryFields {
  final title = TextEditingController();
  final company = TextEditingController();
  final names = TextEditingController();
  _SignatoryFields([Signatory? s]) {
    title.text = s?.title ?? '';
    company.text = s?.company ?? '';
    names.text = s?.names.join('\n') ?? '';
  }
  void dispose() {
    title.dispose();
    company.dispose();
    names.dispose();
  }
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final _tagline = TextEditingController(text: widget.initial.tagline);
  late final _product = TextEditingController(text: widget.initial.productLabel);
  late final _cement = TextEditingController(text: widget.initial.cementLabel);
  late final List<_SignatoryFields> _signs = [for (final s in widget.initial.signatories) _SignatoryFields(s)];
  String? _error;

  @override
  void dispose() {
    _tagline.dispose();
    _product.dispose();
    _cement.dispose();
    for (final s in _signs) {
      s.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_product.text.trim().isEmpty || _cement.text.trim().isEmpty) {
      setState(() => _error = 'Les deux libellés de colonnes sont obligatoires.');
      return;
    }
    final signs = <Signatory>[];
    for (final s in _signs) {
      if (s.title.text.trim().isEmpty) {
        setState(() => _error = 'Chaque signataire doit avoir un poste (ex. « Responsable équipe production »).');
        return;
      }
      signs.add(
        Signatory(
          title: s.title.text.trim(),
          company: s.company.text.trim(),
          names: s.names.text.split('\n').map((n) => n.trim()).where((n) => n.isNotEmpty).toList(),
        ),
      );
    }
    Navigator.pop(
      context,
      ReportSettings(
        tagline: _tagline.text.trim(),
        productLabel: _product.text.trim(),
        cementLabel: _cement.text.trim(),
        signatories: signs,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Signataires et libellés des rapports'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _product,
              decoration: const InputDecoration(
                labelText: 'Colonne des briques *',
                hintText: 'Nombre de BTC confectionnés (14x10x29 cm)',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _cement,
              decoration: const InputDecoration(
                labelText: 'Colonne du ciment *',
                hintText: 'Nombre de sacs de ciment CPA 45',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tagline,
              decoration: const InputDecoration(labelText: 'Devise sous le nom (facultatif)'),
            ),
            const SectionTitle('Signataires (de gauche à droite)'),
            for (final (i, s) in _signs.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassCard(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text('Signataire ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Retirer',
                            icon: const Icon(Icons.delete_outline, color: errColor),
                            onPressed: () => setState(() => _signs.removeAt(i).dispose()),
                          ),
                        ],
                      ),
                      TextField(
                        controller: s.title,
                        decoration: const InputDecoration(
                          labelText: 'Poste *',
                          hintText: 'Responsable équipe production BTC',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: s.company,
                        decoration: const InputDecoration(labelText: 'Structure (facultatif)'),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: s.names,
                        minLines: 1,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: 'Nom(s) : un par ligne',
                          helperText: 'Plusieurs noms : une case à cocher devant chacun sur le document.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_signs.length < 4)
              TextButton.icon(
                onPressed: () => setState(() => _signs.add(_SignatoryFields())),
                icon: const Icon(Icons.add),
                label: const Text('Ajouter un signataire'),
              ),
            if (_error != null) Text(_error!, style: const TextStyle(color: errColor)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Annuler')),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(120, 40)),
        onPressed: _save,
        child: const Text('Enregistrer'),
      ),
    ],
  );
}
