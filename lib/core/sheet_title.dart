import 'format.dart';

/// Titre selon la période choisie : semaine, quinzaine, mois, ou simplement « FICHE DE PAIE ».
String sheetTitle(String from, String to) {
  final a = parseDate(from);
  final b = parseDate(to);
  final days = b.difference(a).inDays + 1;
  final lastOfMonth = DateTime(b.year, b.month + 1, 0).day;
  final sameMonth = a.year == b.year && a.month == b.month;
  if (days <= 7) return 'FICHE DE PAIE HEBDOMADAIRE';
  if (sameMonth && a.day == 1 && b.day == lastOfMonth) return 'FICHE DE PAIE MENSUELLE';
  if (sameMonth && ((a.day == 1 && b.day == 15) || (a.day == 16 && b.day == lastOfMonth))) return 'FICHE DE PAIE DE QUINZAINE';
  return 'FICHE DE PAIE';
}
