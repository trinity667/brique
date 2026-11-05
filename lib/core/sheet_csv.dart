import '../domain/models.dart';
import 'format.dart';
import 'sheet_title.dart';

/// Export « Excel » de la fiche de paie : un fichier CSV (séparateur « ; », BOM UTF-8 ajouté à l'écriture) qui
/// s'ouvre directement dans Excel en français. Même contenu que le PDF : par équipe, le récapitulatif de production,
/// une ligne par ouvrier (jours, total jours, montant, signature vide), les totaux, puis la mention d'état.
/// Montants en FCFA entiers SANS séparateur de milliers, pour qu'Excel les reconnaisse comme des nombres.

String _q(Object? v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';

String _row(List<Object?> cells) => cells.map(_q).join(';');

String _num(Money m) => fmtWhole(m).replaceAll(RegExp(r'[^0-9-]'), '');

String _dm(String date) => fmtDate(date).substring(0, 5);

String _mark(String m) => switch (m) {
      'p' => '1',
      'u' => '?',
      _ => '0',
    };

String payrollSheetCsv(PayrollSheet r, {PayrollSheetRecord? record}) {
  final h = r.head;
  final out = <String>[
    _row([sheetTitle(h.from, h.to)]),
    _row([h.letterhead.name]),
    _row(['Période du ${h.label}']),
    if (record != null) _row(['N°', record.number, 'Statut', record.statusLabel]) else _row(['Aperçu : fiche non établie']),
    '',
  ];
  for (final t in r.teams) {
    final dates = [for (final d in t.days) _dm(d.date)];
    out
      ..add(_row(['${t.name} (poste ${t.shift == 'nuit' ? 'nuit' : 'jour'})', if (r.unitPrice != null) 'Tarif par BTC produit (FCFA) : ${r.unitPrice}']))
      ..add(_row(['Date', '', '', '', '', ...dates, 'Total']))
      ..add(_row(['Quantité produite (BTC)', '', '', '', '', for (final d in t.days) d.working ? d.bricks : '', t.totalBricks]))
      ..add(_row(["Nombre d'agents présents (unités)", '', '', '', '', for (final d in t.days) d.working ? d.present : '', t.totalPresent]))
      ..add(_row(['Montant par unité présente (FCFA/jour)', '', '', '', '', for (final d in t.days) d.working ? _num(d.share) : '', _num(t.totalAmount)]))
      ..add('')
      ..add(_row(['N°', 'Nom et Prénom(s)', 'N° CNIB', 'Village', 'Téléphone', ...dates, 'Total jours', 'Montant total (FCFA)', 'Signature']));
    for (final (i, w) in t.workers.indexed) {
      out.add(_row([
        i + 1,
        '${w.fullName}${w.substitute ? ' (remplaçant)' : ''}',
        w.cnib,
        w.village,
        w.phone,
        for (var k = 0; k < t.days.length; k++) t.days[k].working ? _mark(w.marks[k]) : '',
        w.days,
        _num(w.total),
        '',
      ]));
    }
    out
      ..add(_row(['', 'TOTAL GÉNÉRAL', '', '', '', for (final d in t.days) d.working ? d.present : '', t.totalPresent, _num(t.totalAmount), '']))
      ..add('');
  }
  if (r.teams.length > 1) out.add(_row(['TOTAL GÉNÉRAL DES ÉQUIPES', '', '', '', '', 'BTC', r.totalBricks, 'FCFA', _num(r.totalAmount)]));
  if (record != null) {
    out
      ..add('')
      ..add(_row(['Établie par ${record.establishedBy.name} le ${fmtDateTime(record.establishedBy.at)}']));
    if (record.approvedBy != null) out.add(_row(['Approuvée par ${record.approvedBy!.name} le ${fmtDateTime(record.approvedBy!.at)}']));
    if (record.cancelled != null) out.add(_row(['Annulée par ${record.cancelled!.by} : ${record.cancelled!.reason}']));
  }
  return out.join('\r\n');
}
