import 'dart:convert';
import 'dart:typed_data';

/// Texte d'un fichier CSV/TXT exporté par Excel. Selon l'enregistrement, l'encodage est :
/// - UTF-8 (« CSV UTF-8 »), avec ou sans BOM ;
/// - UTF-16 (« Texte Unicode »), reconnu à son BOM ;
/// - Windows-1252 / Latin-1 (« CSV » classique d'Excel en français) : repli quand l'UTF-8 est invalide,
///   pour que « é », « è », « ç » ne deviennent pas des « � ».
String decodeCsvBytes(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes, 2, Endian.little);
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes, 2, Endian.big);
  var data = bytes;
  if (data.length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) data = data.sublist(3);
  try {
    return utf8.decode(data);
  } on FormatException {
    return latin1.decode(data);
  }
}

/// Octets d'un CSV prêt pour Excel en français : UTF-8 avec BOM (les accents s'affichent correctement).
Uint8List encodeCsv(String text) => Uint8List.fromList(utf8.encode('\u{FEFF}$text'));

String _utf16(Uint8List b, int start, Endian endian) {
  final view = ByteData.sublistView(b);
  final units = <int>[for (var i = start; i + 1 < b.length; i += 2) view.getUint16(i, endian)];
  return String.fromCharCodes(units);
}
