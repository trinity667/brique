import 'dart:convert';
import 'dart:typed_data';

import 'package:app/core/csv_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const text = 'Nom;Village\nKaboré Fidèle;Bouboulou\nOuédraogo Aimé;Koala';

  test('UTF-8 avec ou sans BOM', () {
    expect(decodeCsvBytes(Uint8List.fromList(utf8.encode(text))), text);
    expect(decodeCsvBytes(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)])), text);
  });

  test("« CSV » d'Excel français (Windows-1252 / Latin-1) : les accents ne deviennent pas des « � »", () {
    expect(decodeCsvBytes(Uint8List.fromList(latin1.encode(text))), text);
  });

  test('« Texte Unicode » d\'Excel (UTF-16, avec BOM)', () {
    final le = <int>[0xFF, 0xFE, for (final u in text.codeUnits) ...[u & 0xFF, u >> 8]];
    final be = <int>[0xFE, 0xFF, for (final u in text.codeUnits) ...[u >> 8, u & 0xFF]];
    expect(decodeCsvBytes(Uint8List.fromList(le)), text);
    expect(decodeCsvBytes(Uint8List.fromList(be)), text);
  });

  test('fichier vide', () {
    expect(decodeCsvBytes(Uint8List(0)), '');
  });
}
