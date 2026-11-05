import 'package:flutter/material.dart';

import '../data/app_store.dart';
import 'face_capture.dart';
import 'widgets.dart';

/// Enregistrement du visage (admin, ou superviseur pour un membre de son équipe la première fois) :
/// consentement, 3 photos, puis le serveur calcule et chiffre la signature et jette les photos.
/// Retourne true si le visage est enregistré.
Future<bool> enrollFaceFlow(BuildContext context, AppStore store, String workerId, String fullName) async {
  if (!await confirm(
    context,
    'Consentement',
    '$fullName accepte-t-il l\'enregistrement de son visage pour confirmer sa présence ? '
        'Seule une signature numérique chiffrée est conservée, jamais la photo.',
    ok: 'Il accepte',
  )) {
    return false;
  }
  if (!context.mounted) return false;
  final shots = await captureFaces(
    context,
    title: 'Visage de $fullName',
    count: 3,
    prompts: const [
      'Regardez droit devant',
      'Tournez très légèrement la tête à gauche',
      'Tournez très légèrement la tête à droite',
    ],
  );
  if (shots == null || !context.mounted) return false;
  toast(context, 'Analyse du visage en cours…');
  return run(context, () => store.repo.enrollFace(workerId, shots), success: 'Visage enregistré.');
}
