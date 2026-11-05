import 'dart:io';

import 'package:app/core/documents.dart';
import 'package:app/core/format.dart';
import 'package:app/core/invoice_pdf.dart';
import 'package:app/core/report_pdf.dart';
import 'package:app/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _m(String v) => {'exact': '$v/1', 'value': '$v.00', 'approx': false};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pdfSafe retire seulement ce que la police ne sait pas afficher (les accents restent)', () {
    expect(pdfSafe('≈ 1 000 ✓ é Ê'), '≈ 1 000  é Ê');
  });

  test('fiche de paie, état mensuel et période : PDF valides', () async {
    final sheet = WorkerSheet.fromJson({
      'worker': {'id': 'w', 'fullName': 'Awa Traoré', 'active': true, 'faceEnrolled': true, 'isSupervisor': false, 'teamId': null, 'teamName': null},
      'month': '2026-03',
      'locked': false,
      'stats': {'present': 1, 'absent': 1, 'unset': 0, 'attendanceRate': 0.5, 'absences': {'sick': 1}},
      'earned': _m('1750'),
      'paid': 0,
      'advanced': 500,
      'advances': [
        {'id': 'a', 'amount': 500, 'givenAt': '2026-03-05', 'mode': 'cash', 'note': 'Quinzaine'},
      ],
      'balance': _m('1250'),
      'lines': [
        {'date': '2026-03-02', 'teamName': 'Équipe A', 'status': 'present', 'isSubstitute': false, 'faceVerified': true, 'absenceReason': null, 'dayStatus': 'ok', 'share': _m('1750')},
        {'date': '2026-03-03', 'teamName': 'Équipe A', 'status': 'absent', 'isSubstitute': false, 'faceVerified': false, 'absenceReason': 'sick', 'dayStatus': 'ok', 'share': null},
      ],
      'payments': [],
    });
    final a = await payslipPdf(sheet);
    expect(String.fromCharCodes(a.take(5)), '%PDF-');

    final period = PeriodReport.fromJson({
      'from': '2026-03-01', 'to': '2026-03-07', 'label': '01/03/2026 au 07/03/2026', 'days': 7, 'bricks': 100,
      'cost': _m('17500'), 'sale': _m('25000'), 'margin': _m('7500'), 'incompleteDays': 1,
      'teams': [{'name': 'Équipe A', 'total': _m('17500')}],
      'workers': [{'workerId': 'w', 'fullName': 'Awa Traoré', 'days': 1, 'total': _m('1750')}],
    });
    expect(String.fromCharCodes((await periodPdf(period)).take(5)), '%PDF-');
  });

  test('fmtWhole : FCFA entiers, 0,5 arrondi vers le haut', () {
    Money m(String v) => Money('0/1', v, false);
    // Séparateur de milliers = celui de fmtInt (espace insécable), pas un espace ordinaire.
    expect(fmtWhole(m('19736.11')), fmtInt(19736));
    expect(fmtWhole(m('18987.50')), fmtInt(18988));
    expect(fmtWhole(m('1234567.00')), fmtInt(1234567));
    expect(fmtWhole(m('0.00')), '0');
  });

  test('fiche de paie sur période : titre selon la période, PDF valide (une page ou blocs + récapitulatif)', () async {
    expect(sheetTitle('2026-10-05', '2026-10-11'), 'FICHE DE PAIE HEBDOMADAIRE');
    expect(sheetTitle('2026-10-01', '2026-10-15'), 'FICHE DE PAIE DE QUINZAINE');
    expect(sheetTitle('2026-10-16', '2026-10-31'), 'FICHE DE PAIE DE QUINZAINE');
    expect(sheetTitle('2026-10-01', '2026-10-31'), 'FICHE DE PAIE MENSUELLE');
    expect(sheetTitle('2026-10-03', '2026-10-20'), 'FICHE DE PAIE');

    // Équipe de la fiche papier du 01 au 15/10/2026 (production à partir du 10), 175 FCFA par brique.
    const bricks = [0, 0, 0, 0, 0, 0, 0, 0, 0, 84, 714, 751, 1015, 1008, 651];
    const rows = {
      'OUEDRAOGO Hubert': '000000000111111',
      'OUEDRAOGO Arzouma dit Grégoire': '000000000011111',
      'OUEDRAOGO Adama': '000000000000000',
      'OUEDRAOGO Daniel': '000000000010110',
      'KIENTEGA Parfait Yannick': '000000000001100',
      'TENKOODOGO Salifou': '000000000111111',
      'TENKOODOGO Konyimesom Robert': '000000000111111',
      'TINKOODOGO Adama': '000000000100111',
      'BAMOGO Clément': '000000000001111',
      'OUMTOUGOU Joseph': '000000000111110',
    };
    Map<String, dynamic> sheet(int nDays) {
      final present = [for (var d = 0; d < nDays; d++) d < 15 ? rows.values.where((r) => r[d] == '1').length : 0];
      final days = [
        for (var d = 0; d < nDays; d++)
          {
            'date': '2026-10-${(d + 1).toString().padLeft(2, '0')}',
            'working': d % 7 != 6, // un dimanche sur sept : repos
            'entered': d < 15,
            'bricks': d < 15 ? bricks[d] : 0,
            'present': present[d],
            'share': _m(d < 15 && present[d] > 0 ? (bricks[d] * 175 / present[d]).toStringAsFixed(2).replaceAll('.00', '') : '0'),
            'amount': _m(d < 15 ? '${bricks[d] * 175}' : '0'),
            'incomplete': false,
          },
      ];
      return {
        'from': '2026-10-01', 'to': '2026-10-${nDays.toString().padLeft(2, '0')}', 'label': '01/10/2026 au $nDays/10/2026',
        'team': null, 'unitPrice': 175, 'totalBricks': 4223, 'totalAmount': _m('739025'),
        'letterhead': {'name': 'ASSOCIATION BAYIIR MÊTBA', 'footer': 'Siège social : YAKO', 'place': 'Ouagadougou', 'signer': 'Le Trésorier'},
        'settings': {
          'tagline': '', 'productLabel': 'BTC', 'cementLabel': 'Ciment',
          'signatories': [
            {'title': 'Le Trésorier', 'company': '', 'names': ['BAMOGO Victor']},
            {'title': 'Le Président', 'company': '', 'names': ['OUEDRAOGO Paul']},
          ],
        },
        'client': null,
        'teams': [
          {
            'teamId': 't', 'name': 'Équipe B', 'shift': 'jour', 'days': days,
            'workers': [
              for (final e in rows.entries)
                {
                  'workerId': e.key, 'fullName': e.key, 'cnib': 'B123456', 'village': 'Rawinma', 'phone': '67 04 15 24',
                  'substitute': false,
                  'marks': [for (var d = 0; d < nDays; d++) d < 15 ? (e.value[d] == '1' ? 'p' : 'a') : 'n'],
                  'days': e.value.split('1').length - 1,
                  'total': _m('${(e.value.split('1').length - 1) * 17000}'),
                },
            ],
            'totalBricks': 4223, 'totalPresent': 41, 'totalAmount': _m('739025'),
          },
        ],
      };
    }

    final short = await payrollSheetPdf(PayrollSheet.fromJson(sheet(15)));
    expect(String.fromCharCodes(short.take(5)), '%PDF-');
    final long = await payrollSheetPdf(PayrollSheet.fromJson(sheet(31)));
    expect(String.fromCharCodes(long.take(5)), '%PDF-');
    // 31 jours = 3 blocs + récapitulatif : plus de pages que la fiche d'une quinzaine.
    expect(long.length, greaterThan(short.length));

    // Pour contrôler le rendu à l'œil : SHEET_OUT=dossier flutter test test/documents_test.dart
    final out = Platform.environment['SHEET_OUT'];
    if (out != null) {
      File('$out/fiche-15-jours.pdf').writeAsBytesSync(short);
      File('$out/fiche-31-jours.pdf').writeAsBytesSync(long);
    }

    // Fiche ÉTABLIE : numéro et mention d'état (en attente, approuvée, annulée) sur le PDF.
    for (final status in ['established', 'approved', 'cancelled']) {
      final rec = PayrollSheetRecord.fromJson({
        'id': 'i', 'number': 'FP-2026-001', 'status': status, 'from': '2026-10-01', 'to': '2026-10-15',
        'label': '01/10/2026 au 15/10/2026', 'teamNames': ['Équipe B'], 'totalBricks': 4223, 'totalAmount': _m('739025'),
        'establishedBy': {'name': 'BAMOGO Victor', 'at': '2026-10-16T09:00:00.000Z'},
        if (status == 'approved') 'approvedBy': {'name': 'OUEDRAOGO Paul', 'at': '2026-10-16T10:30:00.000Z'},
        if (status == 'cancelled') 'cancelled': {'by': 'OUEDRAOGO Paul', 'at': '2026-10-17T08:00:00.000Z', 'reason': 'Montants contestés'},
        'sheet': sheet(15),
      });
      final bytes = await payrollSheetPdf(rec.sheet!, record: rec);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      if (out != null) File('$out/fiche-$status.pdf').writeAsBytesSync(bytes);
    }
  });

  test('facture : PDF valide avec en-tête, client et montant en lettres', () async {
    final inv = Invoice.fromJson({
      'id': 'i', 'number': 'ABM/SOPAMIB/2026-07-001', 'issuedOn': '2026-07-15', 'place': 'Ouagadougou',
      'subject': 'Production hebdomadaire de briques BTC (08 au 12 juillet 2026)', 'unitPrice': 200,
      'lines': [
        {'date': '2026-07-08', 'label': 'Brique BTC', 'qty': 169},
        {'date': '2026-07-11', 'label': 'Brique BTC', 'qty': 0},
        {'date': null, 'label': 'Brique BTC (Echantillons)', 'qty': 243},
      ],
      'totalQty': 412, 'totalAmount': 82400, 'amountWords': 'Quatre-vingt-deux mille quatre cents (82 400) francs CFA',
      'signer': 'Le Trésorier',
      'client': {'id': 'c', 'code': 'SOPAMIB', 'name': 'SOPAMIB BOUBOULOU S.A.', 'status': "Société d'État", 'rccm': 'N° BF OUA 01 2024 B30 14310', 'ifu': 'N° 00248483L', 'capital': '10 000 000 Francs CFA', 'address': 'Ouaga 2000', 'active': true},
      'letterhead': {'name': 'ASSOCIATION BAYIIR MÊTBA', 'footer': 'Siege social: YAKO, village Rawinma   Tél: 76 68 47 73 / 62 38 60 56   Passoré - Burkina Faso', 'place': 'Ouagadougou', 'signer': 'Le Trésorier'},
      'status': 'issued',
    });
    final bytes = await invoicePdf(inv);
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    expect(bytes.length, greaterThan(20000)); // polices et logo embarqués
  });
}
