import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/csv_text.dart';
import '../../core/documents.dart';
import '../../core/format.dart';
import '../../core/report_pdf.dart';
import '../../core/sheet_csv.dart';
import '../../core/theme.dart';
import '../../data/app_store.dart';
import '../../domain/models.dart';
import '../glass.dart';
import '../widgets.dart';

Color _statusColor(PayrollSheetRecord r) => r.isApproved ? okColor : (r.isCancelled ? textMuted : warnColor);

String _fileBase(PayrollSheetRecord r) => 'fiche-de-paie-${r.number}-${r.from}-${r.to}';

/// Fiches de paie ÉTABLIES (figées et numérotées). Circuit : un admin (le trésorier) établit la fiche depuis
/// « Paie sur période » ; le président l'approuve, jamais la personne qui l'a établie. Une fiche ne se supprime
/// pas : seule l'annulation motivée est possible.
class PayrollSheetsScreen extends StatefulWidget {
  const PayrollSheetsScreen({super.key});

  @override
  State<PayrollSheetsScreen> createState() => _PayrollSheetsScreenState();
}

class _PayrollSheetsScreenState extends State<PayrollSheetsScreen> {
  Future<List<PayrollSheetRecord>>? _future;
  String? _status; // null = toutes

  void _reload() {
    final next = StoreScope.of(context).repo.payrollSheets(status: _status);
    setState(() {
      _future = next;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= StoreScope.of(context).repo.payrollSheets(status: _status);
  }

  Future<void> _open(PayrollSheetRecord r) async {
    final store = StoreScope.of(context);
    await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => StoreScope(store: store, child: PayrollSheetDetailScreen(id: r.id, number: r.number))));
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return AsyncBody<List<PayrollSheetRecord>>(
      future: _future!,
      onRetry: _reload,
      builder: (context, list) => RefreshIndicator(
        onRefresh: () async {
          _reload();
          await _future;
        },
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Expanded(
              child: Wrap(spacing: 8, runSpacing: 4, children: [
                for (final (label, value) in const [
                  ('Toutes', null),
                  ("En attente d'approbation", 'established'),
                  ('Approuvées', 'approved'),
                  ('Annulées', 'cancelled'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _status == value,
                    onSelected: (_) {
                      _status = value;
                      _reload();
                    },
                  ),
              ]),
            ),
            IconButton(tooltip: 'Actualiser', icon: const Icon(Icons.refresh), onPressed: _reload),
          ]),
          const SizedBox(height: 8),
          const InfoBanner(
            icon: Icons.info_outline,
            color: accent,
            text: "Pour établir une fiche : « Paie sur période », choisissez les dates et les équipes, puis « Établir la fiche ». "
                "Elle est alors figée et numérotée ; le président doit l'approuver.",
          ),
          const SizedBox(height: 12),
          if (list.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Aucune fiche.'))),
          for (final r in list) ...[
            GlassCard(
              child: ListTile(
                onTap: () => _open(r),
                leading: CircleAvatar(
                  backgroundColor: _statusColor(r).withValues(alpha: 0.18),
                  child: Icon(r.isApproved ? Icons.verified : (r.isCancelled ? Icons.block : Icons.hourglass_top), color: _statusColor(r)),
                ),
                title: Text('${r.number} · ${r.label}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${r.teamNames.join(', ')}\nÉtablie par ${r.establishedBy.name} le ${fmtDateTime(r.establishedBy.at)}'),
                isThreeLine: true,
                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(fmtMoney(r.totalAmount), style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Pill(r.statusLabel, _statusColor(r)),
                ]),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ]),
      ),
    );
  }
}

/// Détail d'une fiche établie : contrôle avant approbation, PDF / impression / Excel, approbation, annulation.
class PayrollSheetDetailScreen extends StatefulWidget {
  final String id;
  final String number;
  const PayrollSheetDetailScreen({super.key, required this.id, required this.number});

  @override
  State<PayrollSheetDetailScreen> createState() => _PayrollSheetDetailScreenState();
}

class _PayrollSheetDetailScreenState extends State<PayrollSheetDetailScreen> {
  Future<PayrollSheetRecord>? _future;
  bool _busy = false;

  void _reload() {
    final next = StoreScope.of(context).repo.payrollSheetRecord(widget.id);
    setState(() {
      _future = next;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= StoreScope.of(context).repo.payrollSheetRecord(widget.id);
  }

  Future<void> _act(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    final ok = await run(context, action, success: success);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _reload();
  }

  Future<void> _approve(PayrollSheetRecord r) async {
    final repo = StoreScope.of(context).repo;
    if (!await confirm(context, 'Approuver la fiche ${r.number} ?',
            'Vous attestez avoir contrôlé les présences et les montants (${fmtMoney(r.totalAmount)}). '
            'Une fiche approuvée ne peut plus être modifiée ; seul le président peut l\'annuler, avec un motif.',
            ok: 'Approuver') ||
        !mounted) {
      return;
    }
    await _act(() => repo.approvePayrollSheet(r.id), 'Fiche approuvée.');
  }

  Future<void> _cancel(PayrollSheetRecord r) async {
    final repo = StoreScope.of(context).repo;
    final reason = await askText(context, title: 'Annuler la fiche ${r.number}', label: 'Motif (obligatoire)');
    if (reason == null || reason.trim().length < 3 || !mounted) return;
    await _act(() => repo.cancelPayrollSheet(r.id, reason.trim()), 'Fiche annulée.');
  }

  Future<void> _pdf(PayrollSheetRecord r, {required bool print}) async {
    final bytes = await payrollSheetPdf(r.sheet!, record: r);
    if (print) {
      await Printing.layoutPdf(onLayout: (_) async => bytes, name: _fileBase(r));
    } else {
      await sharePdf(bytes, '${_fileBase(r)}.pdf');
    }
  }

  Future<void> _csv(PayrollSheetRecord r) async {
    final name = '${_fileBase(r)}.csv';
    await SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(encodeCsv(payrollSheetCsv(r.sheet!, record: r)), mimeType: 'text/csv', name: name)],
      fileNameOverrides: [name],
      subject: name,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final me = StoreScope.of(context).user!;
    return Scaffold(
      appBar: AppBar(flexibleSpace: const GlassBar(child: SizedBox.expand()), title: Text('Fiche ${widget.number}')),
      body: AsyncBody<PayrollSheetRecord>(
        future: _future!,
        onRetry: _reload,
        builder: (context, r) {
          final mine = r.establishedBy.name.toLowerCase() == me.name.toLowerCase();
          final canApprove = r.isEstablished && me.isPresident && !mine;
          final canCancel = r.isEstablished || (r.isApproved && me.isPresident);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                InfoBanner(
                  icon: r.isApproved ? Icons.verified : (r.isCancelled ? Icons.block : Icons.hourglass_top),
                  color: _statusColor(r),
                  text: r.isApproved
                      ? 'Approuvée par ${r.approvedBy!.name} le ${fmtDateTime(r.approvedBy!.at)}.'
                      : r.isCancelled
                          ? 'Annulée par ${r.cancelled!.by} le ${fmtDateTime(r.cancelled!.at)} : ${r.cancelled!.reason}'
                          : (me.isPresident && mine)
                              ? "Vous avez établi cette fiche : une autre personne doit l'approuver."
                              : "En attente d'approbation par le président.",
                ),
                const SizedBox(height: 12),
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      KeyValue('Période', r.label),
                      KeyValue('Équipes', r.teamNames.join(', ')),
                      KeyValue('Briques', fmtInt(r.totalBricks)),
                      KeyValue('Total à payer', fmtMoney(r.totalAmount), bold: true),
                      const Divider(height: 20),
                      KeyValue('Établie par', '${r.establishedBy.name} · ${fmtDateTime(r.establishedBy.at)}'),
                      if (r.approvedBy != null) KeyValue('Approuvée par', '${r.approvedBy!.name} · ${fmtDateTime(r.approvedBy!.at)}'),
                    ]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    FilledButton.icon(
                        onPressed: () => _pdf(r, print: false), icon: const Icon(Icons.picture_as_pdf_outlined, size: 18), label: const Text('PDF')),
                    OutlinedButton.icon(
                        onPressed: () => _pdf(r, print: true), icon: const Icon(Icons.print_outlined, size: 18), label: const Text('Imprimer')),
                    OutlinedButton.icon(
                        onPressed: () => _csv(r), icon: const Icon(Icons.table_chart_outlined, size: 18), label: const Text('Excel (CSV)')),
                  ]),
                ),
                if (canApprove || canCancel)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      if (canApprove)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(backgroundColor: okColor),
                          onPressed: _busy ? null : () => _approve(r),
                          icon: const Icon(Icons.verified_outlined, size: 18),
                          label: const Text('Approuver'),
                        ),
                      if (canCancel)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(foregroundColor: errColor),
                          onPressed: _busy ? null : () => _cancel(r),
                          icon: const Icon(Icons.block, size: 18),
                          label: const Text('Annuler la fiche'),
                        ),
                    ]),
                  ),
                for (final t in r.sheet!.teams) ...[
                  SectionTitle('${t.name} · ${fmtMoney(t.totalAmount)}'),
                  GlassCard(
                    child: Column(children: [
                      for (final w in t.workers)
                        ListTile(
                          dense: true,
                          title: Text('${w.fullName}${w.substitute ? ' (remplaçant)' : ''}'),
                          subtitle: Text('${w.days} jour${w.days > 1 ? 's' : ''}'),
                          trailing: Text('${fmtWhole(w.total)} FCFA', style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                    ]),
                  ),
                ],
                const SizedBox(height: 24),
              ]),
            ),
          );
        },
      ),
    );
  }
}
