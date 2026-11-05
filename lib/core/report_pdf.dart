import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../domain/models.dart';
import 'documents.dart';
import 'format.dart';
import 'sheet_title.dart';

export 'sheet_title.dart' show sheetTitle;

/// Rapports officiels du président : rapport de production (modèle du rapport papier BTC),
/// fiche de paie globale des équipes et rapport de présence.
/// En-tête au format des factures de l'association : logo, nom, filet, titre, lieu et date, puis
/// les références du client choisi (statut, RCCM, IFU, capital, siège). Libellés et signataires
/// viennent des réglages enregistrés sur le serveur : rien n'est écrit en dur ici.
const _green = PdfColor.fromInt(0xFF1F5C2E);
const _greenLight = PdfColor.fromInt(0xFFE8F0E9);
const _blue = PdfColor.fromInt(0xFF3A5A9B);
const _gold = PdfColor.fromInt(0xFFF6E7C1);

String shiftLabel(String s) => s == 'nuit' ? 'Nuit' : 'Jour';

Future<pw.MemoryImage> _logo() async => pw.MemoryImage((await rootBundle.load('assets/logo.png')).buffer.asUint8List());

pw.Widget _kv(String k, String v) => pw.Padding(
  padding: const pw.EdgeInsets.only(bottom: 1.5),
  child: pw.RichText(
    text: pw.TextSpan(
      style: const pw.TextStyle(fontSize: 9.5),
      children: [
        pw.TextSpan(
          text: '$k : ',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
        ),
        pw.TextSpan(text: pdfSafe(v)),
      ],
    ),
  ),
);

/// En-tête (1re page) : logo, nom de l'association, filet, titre en bleu, lieu et date, période, client.
pw.Widget _header(ReportHead h, pw.MemoryImage logo, String title) {
  final lh = h.letterhead;
  final c = h.client;
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Image(logo, width: 76, height: 76, alignment: pw.Alignment.centerLeft),
      pw.SizedBox(height: 4),
      pw.Text(pdfSafe(lh.name), style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
      if (h.settings.tagline.isNotEmpty)
        pw.Text(pdfSafe(h.settings.tagline), style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic)),
      pw.Divider(height: 8, thickness: 0.8, color: PdfColors.black),
      pw.SizedBox(height: 10),
      pw.Text(
        pdfSafe(title),
        style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: _blue),
      ),
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          pdfSafe('${lh.place}, le ${fmtDate(dateKey(DateTime.now()))}'),
          style: pw.TextStyle(fontSize: 10, fontStyle: pw.FontStyle.italic),
        ),
      ),
      pw.Text(
        pdfSafe('Période du ${h.label}${h.team == null ? '' : ' · ${h.team}'}'),
        style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
      ),
      if (c != null) ...[
        pw.SizedBox(height: 8),
        pw.Text(
          pdfSafe('CLIENT : ${c.name}'),
          style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _green),
        ),
        pw.SizedBox(height: 3),
        if ((c.status ?? '').isNotEmpty) _kv('Statut', c.status!),
        if ((c.rccm ?? '').isNotEmpty) _kv('RCCM', c.rccm!),
        if ((c.ifu ?? '').isNotEmpty) _kv('IFU', c.ifu!),
        if ((c.capital ?? '').isNotEmpty) _kv('Capital social', c.capital!),
        if ((c.address ?? '').isNotEmpty) _kv('Siège social', c.address!),
      ],
      pw.SizedBox(height: 10),
    ],
  );
}

pw.Widget _footer(Letterhead lh, pw.Context c) => pw.Column(
  children: [
    pw.Divider(height: 8, thickness: 0.6, color: PdfColors.grey700),
    pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text(pdfSafe(lh.footer), style: const pw.TextStyle(fontSize: 8), textAlign: pw.TextAlign.center),
        ),
        pw.Text('${c.pageNumber}/${c.pagesCount}', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
      ],
    ),
  ],
);

pw.Widget _cell(
  String t, {
  pw.Alignment align = pw.Alignment.center,
  bool bold = false,
  PdfColor? color,
  double size = 9,
}) => pw.Container(
  alignment: align,
  padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3.5),
  child: pw.Text(
    pdfSafe(t),
    textAlign: pw.TextAlign.center,
    style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : null, color: color),
  ),
);

pw.TableRow _head(List<String> labels, {double size = 9}) => pw.TableRow(
  decoration: const pw.BoxDecoration(color: _green),
  repeat: true,
  children: [for (final l in labels) _cell(l.toUpperCase(), bold: true, color: PdfColors.white, size: size)],
);

/// Case à cocher : cadre fin, croix si cochée.
pw.Widget _box(bool checked, {double size = 10}) => pw.Container(
  width: size,
  height: size,
  decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8)),
  child: checked
      ? pw.CustomPaint(
          size: PdfPoint(size, size),
          painter: (canvas, s) => canvas
            ..setStrokeColor(PdfColors.black)
            ..setLineWidth(1)
            ..moveTo(1.5, 1.5)
            ..lineTo(s.x - 1.5, s.y - 1.5)
            ..moveTo(1.5, s.y - 1.5)
            ..lineTo(s.x - 1.5, 1.5)
            ..strokePath(),
        )
      : null,
);

/// Zones de signature côte à côte (réglages du président) : « Signature : », poste, structure,
/// espace pour signer et cacheter, puis le ou les noms (case à cocher devant chacun s'il y en a plusieurs).
pw.Widget _signatures(List<Signatory> list, {double top = 16, double gap = 46}) {
  if (list.isEmpty) return pw.SizedBox();
  return pw.Padding(
    padding: pw.EdgeInsets.only(top: top),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final s in list)
          pw.Expanded(
            child: pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 4),
              child: pw.Column(
                children: [
                  pw.Text('Signature :', style: pw.TextStyle(fontSize: 9.5, fontWeight: pw.FontWeight.bold)),
                  pw.Text(
                    pdfSafe(s.title),
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
                  ),
                  if (s.company.isNotEmpty)
                    pw.Text(
                      pdfSafe(s.company),
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
                    ),
                  pw.SizedBox(height: gap),
                  if (s.names.length == 1)
                    pw.Text(
                      pdfSafe(s.names.first),
                      textAlign: pw.TextAlign.center,
                      style: const pw.TextStyle(fontSize: 9),
                    )
                  else
                    for (final n in s.names)
                      pw.Padding(
                        padding: const pw.EdgeInsets.only(bottom: 2),
                        child: pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.center,
                          children: [
                            pw.Text(pdfSafe(n), style: const pw.TextStyle(fontSize: 9)),
                            pw.SizedBox(width: 6),
                            _box(false, size: 8),
                          ],
                        ),
                      ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

Future<pw.Document> _doc(String title) async => pw.Document(title: title, theme: await pdfTheme());

pw.MultiPage _page(ReportHead h, pw.MemoryImage logo, String title, List<pw.Widget> body, {bool landscape = false}) =>
    pw.MultiPage(
      pageFormat: landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 28, 36, 30),
      footer: (c) => _footer(h.letterhead, c),
      build: (_) => [_header(h, logo, title), ...body],
    );

/// Rapport de production : date + poste, BTC, sacs de ciment, total, montant à payer, signatures.
Future<Uint8List> productionPdf(ProductionReport r) async {
  final logo = await _logo();
  final s = r.head.settings;
  final doc = await _doc('Rapport de production ${r.head.label}');
  doc.addPage(
    _page(r.head, logo, 'RAPPORT DE PRODUCTION', [
      pw.Table(
        border: pw.TableBorder.all(width: 0.6),
        columnWidths: const {0: pw.FlexColumnWidth(1.5), 1: pw.FlexColumnWidth(1.6), 2: pw.FlexColumnWidth(1.4)},
        children: [
          _head(['Date / poste', s.productLabel, s.cementLabel]),
          for (final x in r.rows)
            pw.TableRow(
              children: [
                _cell('${fmtDate(x.date)} ${shiftLabel(x.shift)}', align: pw.Alignment.centerLeft),
                _cell(fmtInt(x.bricks)),
                _cell(fmtInt(x.cementBags)),
              ],
            ),
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _gold),
            children: [
              _cell('TOTAL', bold: true),
              _cell(fmtInt(r.totalBricks), bold: true),
              _cell(fmtInt(r.totalCement), bold: true),
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Table(
        border: pw.TableBorder.all(width: 0.6),
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _greenLight),
            children: [
              _cell('Nombre BTC', bold: true),
              _cell('Prix unitaire (FCFA)', bold: true),
              _cell('Montant à payer (FCFA)', bold: true),
            ],
          ),
          pw.TableRow(
            children: [
              _cell(fmtInt(r.totalBricks), size: 10),
              _cell(r.unitPrice == null ? 'Variable' : fmtInt(r.unitPrice!), size: 10),
              _cell(fmtMoney(r.amount, unit: false), bold: true, size: 10),
            ],
          ),
        ],
      ),
      if (r.missingPrice)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Text(
            'Attention : aucun prix de vente pour certaines dates ; elles ne sont pas comptées dans le montant.',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.red800),
          ),
        ),
      _signatures(s.signatories),
    ]),
  );
  return doc.save();
}

/// Fiche de paie globale : une ligne par date, une colonne « briques » et « somme » par équipe enregistrée.
Future<Uint8List> teamPayrollPdf(TeamPayrollReport r) async {
  final logo = await _logo();
  final doc = await _doc('Fiche de paie globale ${r.head.label}');
  final many = r.teams.length > 2;
  final size = r.teams.length > 4 ? 7.5 : 9.0;
  doc.addPage(
    _page(r.head, logo, 'FICHE DE PAIE GLOBALE DES ÉQUIPES', [
      if (r.unitPrice != null)
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 6),
          child: pw.Text(
            'Prix de confection : ${fmtInt(r.unitPrice!)} FCFA par brique',
            style: const pw.TextStyle(fontSize: 9.5),
          ),
        ),
      pw.Table(
        border: pw.TableBorder.all(width: 0.6),
        children: [
          // 1re ligne : nom de chaque équipe au-dessus de ses deux colonnes.
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _green),
            repeat: true,
            children: [
              _cell('', color: PdfColors.white),
              for (final t in r.teams) ...[
                _cell(t.name.toUpperCase(), bold: true, color: PdfColors.white, size: size),
                _cell('(${shiftLabel(t.shift)})', color: PdfColors.white, size: size),
              ],
              _cell('TOTAL', bold: true, color: PdfColors.white, size: size),
              _cell('', color: PdfColors.white),
            ],
          ),
          _head([
            'Date',
            for (final _ in r.teams) ...['Briques', 'Somme (FCFA)'],
            'Briques',
            'Somme (FCFA)',
          ], size: size),
          for (final d in r.days)
            pw.TableRow(
              children: [
                _cell(fmtDate(d.date), size: size),
                for (final c in d.cells) ...[
                  _cell('${fmtInt(c.bricks)}${c.incomplete ? ' *' : ''}', size: size),
                  _cell(fmtMoney(c.amount, unit: false), align: pw.Alignment.centerRight, size: size),
                ],
                _cell(fmtInt(d.bricks), bold: true, size: size),
                _cell(fmtMoney(d.amount, unit: false), bold: true, align: pw.Alignment.centerRight, size: size),
              ],
            ),
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: _gold),
            children: [
              _cell('TOTAL', bold: true, size: size),
              for (final t in r.teams) ...[
                _cell(fmtInt(t.bricks), bold: true, size: size),
                _cell(fmtMoney(t.amount, unit: false), bold: true, align: pw.Alignment.centerRight, size: size),
              ],
              _cell(fmtInt(r.totalBricks), bold: true, size: size),
              _cell(fmtMoney(r.totalAmount, unit: false), bold: true, align: pw.Alignment.centerRight, size: size),
            ],
          ),
        ],
      ),
      if (r.days.isEmpty)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Text('Aucune production saisie sur la période.'),
        ),
      if (r.days.any((d) => d.cells.any((c) => c.incomplete)))
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Text(
            '* Journée à régulariser (présences non saisies ou aucun présent) avant la paie officielle.',
            style: const pw.TextStyle(fontSize: 8),
          ),
        ),
    ], landscape: many),
  );
  return doc.save();
}

/// Rapport de présence : par équipe, nom et prénoms, nombre de fois présent et case à cocher.
/// `checked` = identifiants cochés dans l'application (case vide sinon, à cocher à la main).
Future<Uint8List> attendancePdf(AttendanceReport r, {Set<String> checked = const {}}) async {
  final logo = await _logo();
  final doc = await _doc('Rapport de présence ${r.head.label}');
  doc.addPage(
    _page(r.head, logo, 'RAPPORT DE PRÉSENCE DES ÉQUIPES', [
      for (final t in r.teams) ...[
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          color: _greenLight,
          child: pw.Row(
            children: [
              pw.Expanded(
                child: pw.Text(
                  pdfSafe(t.name.toUpperCase()),
                  style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _green),
                ),
              ),
              pw.Text(
                pdfSafe('Poste de ${t.shift} · ${t.days} journée(s) saisie(s)'),
                style: const pw.TextStyle(fontSize: 9),
              ),
            ],
          ),
        ),
        pw.Table(
          border: pw.TableBorder.all(width: 0.6),
          columnWidths: const {
            0: pw.FixedColumnWidth(28),
            1: pw.FlexColumnWidth(3),
            2: pw.FlexColumnWidth(1.3),
            3: pw.FlexColumnWidth(1),
            4: pw.FixedColumnWidth(56),
          },
          children: [
            _head(['N°', 'Nom et prénoms', 'Nombre de fois présent', 'Absences', 'Cocher']),
            for (final (i, m) in t.members.indexed)
              pw.TableRow(
                children: [
                  _cell('${i + 1}'),
                  _cell('${m.fullName}${m.substitute ? ' (remplaçant)' : ''}', align: pw.Alignment.centerLeft),
                  _cell('${m.present}', bold: true),
                  _cell('${m.absent}'),
                  pw.Center(
                    child: pw.Padding(
                      padding: const pw.EdgeInsets.symmetric(vertical: 3),
                      child: _box(checked.contains('${t.teamId}|${m.workerId}')),
                    ),
                  ),
                ],
              ),
          ],
        ),
        pw.SizedBox(height: 14),
      ],
    ]),
  );
  return doc.save();
}

// ───────────────────────── Fiche de paie sur période (par équipe, signature de chaque ouvrier) ─────────────────────────

/// Jours par page paysage : au-delà, la période est découpée en blocs, puis un récapitulatif par équipe
/// (montant total sur toute la période, signature) clôt la fiche.
const _sheetDaysPerPage = 15;
const _dayW = 20.0;

pw.Widget _sheetHeader(ReportHead h, pw.MemoryImage logo, String title, {PayrollSheetRecord? rec}) {
  final lh = h.letterhead;
  return pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Image(logo, width: 38, height: 38),
          pw.SizedBox(width: 8),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(pdfSafe(lh.name), style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
                if (h.settings.tagline.isNotEmpty)
                  pw.Text(pdfSafe(h.settings.tagline), style: pw.TextStyle(fontSize: 8, fontStyle: pw.FontStyle.italic)),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                pdfSafe('${lh.place}, le ${fmtDate(dateKey(DateTime.now()))}'),
                style: pw.TextStyle(fontSize: 9, fontStyle: pw.FontStyle.italic),
              ),
              if (rec != null) pw.Text('N° ${rec.number}', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
            ],
          ),
        ],
      ),
      pw.Divider(height: 8, thickness: 0.8, color: PdfColors.black),
      pw.Center(child: pw.Text(pdfSafe(title), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: _blue))),
      pw.Center(
        child: pw.Text(
          pdfSafe('AGENTS PRODUCTEURS DE BRIQUES · Période du ${h.label}'),
          style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
        ),
      ),
      pw.SizedBox(height: 6),
    ],
  );
}

/// Bandeau d'équipe : nom, poste et tarif par brique produite.
pw.Widget _sheetTeamBar(SheetTeam t, int? unitPrice, {String? part}) => pw.Container(
  padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
  margin: const pw.EdgeInsets.only(bottom: 4),
  color: _greenLight,
  child: pw.Row(
    children: [
      pw.Expanded(
        child: pw.Text(
          pdfSafe('${t.name.toUpperCase()} (poste ${shiftLabel(t.shift).toLowerCase()})${part == null ? '' : ' · $part'}'),
          style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: _green),
        ),
      ),
      if (unitPrice != null)
        pw.Text('Tarif par BTC produit (FCFA) : ${fmtInt(unitPrice)}', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
    ],
  ),
);

/// Cellule d'un jour : grisée avec un tiret quand le jour n'est pas travaillé (repos, férié, intempérie…).
pw.Widget _dayCell(String t, {required bool rest, bool bold = false, double size = 7.5, PdfColor? color}) => pw.Container(
  alignment: pw.Alignment.center,
  color: rest ? PdfColors.grey300 : null,
  padding: const pw.EdgeInsets.symmetric(vertical: 4),
  child: pw.Text(rest ? '-' : pdfSafe(t), style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : null, color: color)),
);

String _dm(String date) => fmtDate(date).substring(0, 5);

/// En-tête d'une colonne de jour : « JJ/MM » sur une seule ligne dans une colonne étroite.
pw.Widget _dayHead(String t) => pw.Container(
  alignment: pw.Alignment.center,
  padding: const pw.EdgeInsets.symmetric(vertical: 5),
  child: pw.Text(t, maxLines: 1, softWrap: false, style: pw.TextStyle(fontSize: 5.5, fontWeight: pw.FontWeight.bold, color: PdfColors.white)),
);

String _markText(String m) => switch (m) {
  'p' => '1',
  'u' => '?',
  _ => '0',
};

/// Un bloc de jours [a, b[ d'une équipe : récapitulatif de production, puis présences ouvrier par ouvrier.
/// [single] = la période tient sur une page : on ajoute total jours, montant et signature (modèle papier).
List<pw.Widget> _sheetBlock(SheetTeam t, int? unitPrice, int a, int b, {required bool single, String? part}) {
  final days = t.days.sublist(a, b);
  final dayCols = {for (var i = 0; i < days.length; i++) 5 + i: const pw.FixedColumnWidth(_dayW)};
  const left = <int, pw.TableColumnWidth>{
    0: pw.FixedColumnWidth(20),
    1: pw.FixedColumnWidth(140),
    2: pw.FixedColumnWidth(58),
    3: pw.FixedColumnWidth(52),
    4: pw.FixedColumnWidth(62),
  };
  final recapCols = <int, pw.TableColumnWidth>{
    0: const pw.FixedColumnWidth(332),
    for (var i = 0; i < days.length; i++) 1 + i: const pw.FixedColumnWidth(_dayW),
    if (single) 1 + days.length: const pw.FixedColumnWidth(36),
  };
  pw.Widget label(String s) => pw.Container(
    alignment: pw.Alignment.centerLeft,
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    child: pw.Text(pdfSafe(s), style: const pw.TextStyle(fontSize: 8)),
  );
  final recap = pw.Table(
    border: pw.TableBorder.all(width: 0.5),
    columnWidths: recapCols,
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _greenLight),
        children: [
          label('Date'),
          for (final d in days) _dayCell(_dm(d.date), rest: false, bold: true, size: 6.5),
          if (single) _dayCell('Total', rest: false, bold: true),
        ],
      ),
      pw.TableRow(
        children: [
          label('Quantité produite (BTC)'),
          for (final d in days) _dayCell(fmtInt(d.bricks), rest: !d.working),
          if (single) _dayCell(fmtInt(t.totalBricks), rest: false, bold: true),
        ],
      ),
      pw.TableRow(
        children: [
          label("Nombre d'agents présents (unités)"),
          for (final d in days) _dayCell('${d.present}', rest: !d.working),
          if (single) _dayCell('${t.totalPresent}', rest: false, bold: true),
        ],
      ),
      pw.TableRow(
        children: [
          label('Montant par unité présente (FCFA/jour)'),
          for (final d in days) _dayCell('${fmtWhole(d.share)}${d.incomplete ? '*' : ''}', rest: !d.working, size: 6.5),
          if (single) _dayCell(fmtWhole(t.totalAmount), rest: false, bold: true, size: 6.5),
        ],
      ),
    ],
  );

  final presence = pw.Table(
    border: pw.TableBorder.all(width: 0.5),
    columnWidths: {
      ...left,
      ...dayCols,
      if (single) ...{
        5 + days.length: const pw.FixedColumnWidth(28),
        6 + days.length: const pw.FixedColumnWidth(52),
        7 + days.length: const pw.FixedColumnWidth(80),
      },
    },
    children: [
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _green),
        repeat: true,
        children: [
          for (final h in ['N°', 'Nom et Prénom(s)', 'N° CNIB', 'Village', 'Téléphone']) _cell(h, bold: true, color: PdfColors.white, size: 7),
          for (final d in days) _dayHead(_dm(d.date)),
          if (single) ...[
            _cell('Total jours', bold: true, color: PdfColors.white, size: 6.5),
            _cell('Montant total (FCFA)', bold: true, color: PdfColors.white, size: 6.5),
            _cell('Signature', bold: true, color: PdfColors.white, size: 7),
          ],
        ],
      ),
      for (final (i, w) in t.workers.indexed)
        pw.TableRow(
          children: [
            _cell('${i + 1}', size: 7.5),
            _cell('${w.fullName}${w.substitute ? ' (remplaçant)' : ''}', align: pw.Alignment.centerLeft, size: 7.5),
            _cell(w.cnib, size: 7),
            _cell(w.village, size: 7),
            _cell(w.phone, size: 7),
            for (var k = 0; k < days.length; k++) _dayCell(_markText(w.marks[a + k]), rest: !days[k].working),
            if (single) ...[
              _cell('${w.days}', bold: true, size: 7.5),
              _cell(fmtWhole(w.total), bold: true, align: pw.Alignment.centerRight, size: 7.5),
              pw.SizedBox(height: 19),
            ],
          ],
        ),
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _gold),
        children: [
          _cell('', size: 7.5),
          _cell('TOTAL GÉNÉRAL', bold: true, align: pw.Alignment.centerLeft, size: 7.5),
          _cell('', size: 7),
          _cell('', size: 7),
          _cell('', size: 7),
          for (final d in days) _dayCell('${d.present}', rest: !d.working, bold: true),
          if (single) ...[
            _cell('${t.totalPresent}', bold: true, size: 7.5),
            _cell(fmtWhole(t.totalAmount), bold: true, align: pw.Alignment.centerRight, size: 7.5),
            _cell('', size: 7),
          ],
        ],
      ),
    ],
  );
  return [_sheetTeamBar(t, unitPrice, part: part), recap, pw.SizedBox(height: 8), presence];
}

/// Récapitulatif d'une équipe sur toute la période (périodes longues) : montant total et signature.
List<pw.Widget> _sheetRecap(SheetTeam t, int? unitPrice) => [
  _sheetTeamBar(t, unitPrice, part: 'RÉCAPITULATIF DE LA PÉRIODE'),
  pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 6),
    child: pw.Text(
      '${fmtInt(t.totalBricks)} BTC produits · ${fmtInt(t.totalPresent)} présences · à payer : ${fmtWhole(t.totalAmount)} FCFA',
      style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
    ),
  ),
  pw.Table(
    border: pw.TableBorder.all(width: 0.5),
    columnWidths: const {
      0: pw.FixedColumnWidth(24),
      1: pw.FlexColumnWidth(3),
      2: pw.FlexColumnWidth(1.2),
      3: pw.FlexColumnWidth(1.1),
      4: pw.FlexColumnWidth(1.2),
      5: pw.FixedColumnWidth(48),
      6: pw.FixedColumnWidth(80),
      7: pw.FlexColumnWidth(1.6),
    },
    children: [
      _head(['N°', 'Nom et Prénom(s)', 'N° CNIB', 'Village', 'Téléphone', 'Total jours', 'Montant total (FCFA)', 'Signature'], size: 7.5),
      for (final (i, w) in t.workers.indexed)
        pw.TableRow(
          children: [
            _cell('${i + 1}', size: 8),
            _cell('${w.fullName}${w.substitute ? ' (remplaçant)' : ''}', align: pw.Alignment.centerLeft, size: 8),
            _cell(w.cnib, size: 7.5),
            _cell(w.village, size: 7.5),
            _cell(w.phone, size: 7.5),
            _cell('${w.days}', bold: true, size: 8),
            _cell(fmtWhole(w.total), bold: true, align: pw.Alignment.centerRight, size: 8),
            pw.SizedBox(height: 24),
          ],
        ),
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: _gold),
        children: [
          _cell(''),
          _cell('TOTAL GÉNÉRAL', bold: true, align: pw.Alignment.centerLeft, size: 8),
          _cell(''),
          _cell(''),
          _cell(''),
          _cell('${t.totalPresent}', bold: true, size: 8),
          _cell(fmtWhole(t.totalAmount), bold: true, align: pw.Alignment.centerRight, size: 8),
          _cell(''),
        ],
      ),
    ],
  ),
];

/// Mention d'état en bas de la fiche : numéro, qui l'a établie et approuvée, ou « non établie » pour un aperçu.
pw.Widget _sheetStamp(PayrollSheetRecord? rec) {
  if (rec == null) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(top: 6),
      child: pw.Text(
        "Aperçu : fiche non établie (sans numéro ni approbation).",
        style: pw.TextStyle(fontSize: 8, fontStyle: pw.FontStyle.italic, color: PdfColors.grey700),
      ),
    );
  }
  final color = rec.isApproved ? _green : PdfColors.red800;
  final lines = <String>[
    '${rec.number} · ${rec.statusLabel.toUpperCase()}',
    'Établie par ${rec.establishedBy.name} le ${fmtDateTime(rec.establishedBy.at)}',
    if (rec.approvedBy != null) 'Approuvée par ${rec.approvedBy!.name} le ${fmtDateTime(rec.approvedBy!.at)}',
    if (rec.cancelled != null) 'Annulée par ${rec.cancelled!.by} le ${fmtDateTime(rec.cancelled!.at)} : ${rec.cancelled!.reason}',
  ];
  return pw.Padding(
    padding: const pw.EdgeInsets.only(top: 6),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        for (final (i, l) in lines.indexed)
          pw.Text(pdfSafe(l), style: pw.TextStyle(fontSize: i == 0 ? 9 : 8, fontWeight: i == 0 ? pw.FontWeight.bold : null, color: color)),
      ],
    ),
  );
}

/// Fiche de paie sur la période choisie : une page par équipe (et par bloc de 15 jours si la période est
/// plus longue, avec un récapitulatif signé par ouvrier). Jours de repos grisés. Montants du serveur.
Future<Uint8List> payrollSheetPdf(PayrollSheet r, {PayrollSheetRecord? record}) async {
  final logo = await _logo();
  final head = r.head;
  final doc = await _doc('Fiche de paie ${head.label}');
  final title = '${sheetTitle(head.from, head.to)}${record != null && record.isCancelled ? ' - ANNULÉE' : ''}';
  final nDays = r.teams.isEmpty ? 0 : r.teams.first.days.length;
  final single = nDays <= _sheetDaysPerPage;

  final pages = <List<pw.Widget>>[];
  for (final t in r.teams) {
    if (single) {
      pages.add(_sheetBlock(t, r.unitPrice, 0, nDays, single: true));
      continue;
    }
    final blocks = (nDays / _sheetDaysPerPage).ceil();
    for (var k = 0; k < blocks; k++) {
      final a = k * _sheetDaysPerPage;
      final b = a + _sheetDaysPerPage > nDays ? nDays : a + _sheetDaysPerPage;
      pages.add(_sheetBlock(t, r.unitPrice, a, b, single: false, part: 'du ${_dm(t.days[a].date)} au ${_dm(t.days[b - 1].date)}'));
    }
    pages.add(_sheetRecap(t, r.unitPrice));
  }
  if (pages.isEmpty) pages.add([pw.Text('Aucune équipe enregistrée.')]);

  final incomplete = r.teams.any((t) => t.days.any((d) => d.incomplete));
  final closing = <pw.Widget>[
    if (r.teams.length > 1)
      pw.Container(
        margin: const pw.EdgeInsets.only(top: 8),
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        color: _gold,
        child: pw.Row(
          children: [
            pw.Expanded(child: pw.Text('TOTAL GÉNÉRAL DES ÉQUIPES', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold))),
            pw.Text(
              '${fmtInt(r.totalBricks)} BTC · ${fmtWhole(r.totalAmount)} FCFA',
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
      ),
    if (incomplete)
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 4),
        child: pw.Text(
          '* Journée à régulariser (présences non saisies ou aucun présent) avant la paie officielle.',
          style: const pw.TextStyle(fontSize: 7.5),
        ),
      ),
    _sheetStamp(record),
    _signatures(head.settings.signatories, top: 8, gap: 28),
  ];

  for (final (i, body) in pages.indexed) {
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.fromLTRB(24, 22, 24, 26),
        footer: (c) => _footer(head.letterhead, c),
        build: (_) => [_sheetHeader(head, logo, title, rec: record), ...body, if (i == pages.length - 1) ...closing],
      ),
    );
  }
  return doc.save();
}
