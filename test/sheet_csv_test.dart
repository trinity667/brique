import 'dart:convert';

import 'package:app/core/csv_text.dart';
import 'package:app/core/sheet_csv.dart';
import 'package:app/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _m(String v) => {'exact': '$v/1', 'value': '$v.00', 'approx': false};

Map<String, dynamic> _day(String date, {required bool working, int bricks = 0, int present = 0, String share = '0'}) => {
      'date': date, 'working': working, 'entered': working, 'bricks': bricks, 'present': present,
      'share': _m(share), 'amount': _m('${bricks * 175}'), 'incomplete': false,
    };

Map<String, dynamic> _team(String name) => {
      'teamId': name, 'name': name, 'shift': 'jour',
      'days': [
        _day('2026-10-10', working: true, bricks: 84, present: 5, share: '2940'),
        _day('2026-10-11', working: false), // dimanche : repos
        _day('2026-10-12', working: true, bricks: 714, present: 6, share: '20825'),
      ],
      'workers': [
        {
          'workerId': 'w1', 'fullName': 'OUEDRAOGO "Hubert" Rawinma', 'cnib': 'B1234', 'village': 'Rawinma', 'phone': '67 04 15 24',
          'substitute': false, 'marks': ['p', 'n', 'p'], 'days': 2, 'total': _m('123765'),
        },
        {
          'workerId': 'w2', 'fullName': 'KIENTEGA Parfait', 'cnib': '', 'village': '', 'phone': '',
          'substitute': true, 'marks': ['a', 'n', 'p'], 'days': 1, 'total': _m('20825'),
        },
      ],
      'totalBricks': 798, 'totalPresent': 11, 'totalAmount': _m('139650'),
    };

Map<String, dynamic> _sheet(List<String> teams) => {
      'from': '2026-10-10', 'to': '2026-10-12', 'label': '10/10/2026 au 12/10/2026', 'team': null, 'unitPrice': 175,
      'totalBricks': 798 * teams.length, 'totalAmount': _m('${139650 * teams.length}'),
      'letterhead': {'name': 'ASSOCIATION BAYIIR MÊTBA', 'footer': '', 'place': 'Ouagadougou', 'signer': 'Le Trésorier'},
      'settings': {'tagline': '', 'productLabel': 'BTC', 'cementLabel': 'Ciment', 'signatories': []},
      'client': null,
      'teams': [for (final t in teams) _team(t)],
    };

void main() {
  test('CSV de la fiche : récapitulatif, ouvriers, repos vide, montants sans séparateur, guillemets protégés', () {
    final csv = payrollSheetCsv(PayrollSheet.fromJson(_sheet(['Équipe B'])));
    final lines = csv.split('\r\n');
    expect(lines.first, '"FICHE DE PAIE HEBDOMADAIRE"');
    expect(lines, contains('"Aperçu : fiche non établie"'));
    expect(lines, contains('"Date";"";"";"";"";"10/10";"11/10";"12/10";"Total"'));
    // Le dimanche (repos) reste vide : Excel ne le compte pas ; les montants n'ont pas d'espace de milliers.
    expect(lines, contains('"Quantité produite (BTC)";"";"";"";"";"84";"";"714";"798"'));
    expect(lines, contains('"Montant par unité présente (FCFA/jour)";"";"";"";"";"2940";"";"20825";"139650"'));
    expect(lines, contains('"1";"OUEDRAOGO ""Hubert"" Rawinma";"B1234";"Rawinma";"67 04 15 24";"1";"";"1";"2";"123765";""'));
    expect(lines, contains('"2";"KIENTEGA Parfait (remplaçant)";"";"";"";"0";"";"1";"1";"20825";""'));
    expect(lines.any((l) => l.startsWith('"";"TOTAL GÉNÉRAL"') && l.contains('"139650"')), isTrue);
    // Une seule équipe : pas de total général des équipes.
    expect(csv.contains('TOTAL GÉNÉRAL DES ÉQUIPES'), isFalse);
  });

  test('plusieurs équipes : total général des équipes ; fiche établie : numéro, statut et approbation', () {
    final json = _sheet(['Équipe A', 'Équipe B']);
    final record = PayrollSheetRecord.fromJson({
      'id': 'i', 'number': 'FP-2026-001', 'status': 'approved', 'from': '2026-10-10', 'to': '2026-10-12',
      'label': '10/10/2026 au 12/10/2026', 'teamNames': ['Équipe A', 'Équipe B'], 'totalBricks': 1596,
      'totalAmount': _m('279300'),
      'establishedBy': {'name': 'BAMOGO Victor', 'at': '2026-10-13T09:00:00.000Z'},
      'approvedBy': {'name': 'OUEDRAOGO Paul', 'at': '2026-10-13T10:30:00.000Z'},
    });
    final csv = payrollSheetCsv(PayrollSheet.fromJson(json), record: record);
    expect(csv, contains('"N°";"FP-2026-001";"Statut";"Approuvée"'));
    expect(csv, contains('"TOTAL GÉNÉRAL DES ÉQUIPES";"";"";"";"";"BTC";"1596";"FCFA";"279300"'));
    expect(csv, contains('Établie par BAMOGO Victor le '));
    expect(csv, contains('Approuvée par OUEDRAOGO Paul le '));
    expect(csv.contains('Aperçu'), isFalse);
  });

  test('encodeCsv : UTF-8 avec BOM pour qu\'Excel affiche les accents', () {
    final bytes = encodeCsv('"Équipe"');
    expect(bytes.take(3), [0xEF, 0xBB, 0xBF]);
    expect(utf8.decode(bytes.sublist(3)), '"Équipe"');
  });
}
