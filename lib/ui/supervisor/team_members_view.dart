import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/app_store.dart';
import '../../domain/models.dart';
import '../admin/worker_form.dart';
import '../face_enroll.dart';
import '../glass.dart';
import '../widgets.dart';

/// « Mon équipe » (superviseur) : les membres déjà enregistrés de son équipe, avec l'état du visage.
/// - Première fois : il enregistre ses ouvriers un par un (nom, contact) puis leur visage.
/// - Ensuite : il retrouve la liste, peut ajouter un nouvel ouvrier, en remplacer un ou en retirer un.
/// Aucun montant ni coordonnée n'est affiché ici (le serveur ne les envoie pas au superviseur).
class TeamMembersView extends StatefulWidget {
  const TeamMembersView({super.key});

  @override
  State<TeamMembersView> createState() => _TeamMembersViewState();
}

class _TeamMembersViewState extends State<TeamMembersView> {
  Future<({List<MyTeam> teams, List<WorkerInfo> workers})>? _future;
  String? _teamId;

  Future<({List<MyTeam> teams, List<WorkerInfo> workers})> _fetch() async {
    final repo = StoreScope.of(context).repo;
    final r = await Future.wait([repo.myTeams(), repo.workers()]);
    return (teams: r[0] as List<MyTeam>, workers: r[1] as List<WorkerInfo>);
  }

  void _reload() => setState(() => _future = _fetch());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _fetch();
  }

  /// Formulaire puis, si l'ouvrier est d'accord, enregistrement de son visage dans la foulée.
  Future<void> _add(AppStore store, MyTeam team, {WorkerInfo? replacing}) async {
    if (replacing != null &&
        !await confirm(
          context,
          'Remplacer ${replacing.fullName}',
          '${replacing.fullName} quittera l\'équipe ${team.name} (ses journées passées restent enregistrées). '
              'Vous allez enregistrer la personne qui le remplace.',
          ok: 'Continuer',
        )) {
      return;
    }
    if (!mounted) return;
    final f = await showWorkerForm(
      context,
      title: replacing == null ? 'Nouvel ouvrier · ${team.name}' : 'Remplaçant de ${replacing.fullName}',
    );
    if (f == null || !mounted) return;
    String? id;
    final ok = await run(
      context,
      () async {
        id = replacing == null
            ? await store.repo.addWorker(
                fullName: f.fullName,
                teamId: team.id,
                phone: f.phone,
                village: f.village,
                cnib: f.cnib,
                mobileOperator: f.mobileOperator,
                mobileNumber: f.mobileNumber,
              )
            : await store.repo.replaceWorker(
                replacing.id,
                fullName: f.fullName,
                phone: f.phone,
                village: f.village,
                cnib: f.cnib,
                mobileOperator: f.mobileOperator,
                mobileNumber: f.mobileNumber,
              );
      },
      success: replacing == null
          ? '${f.fullName} ajouté à l\'équipe.'
          : '${f.fullName} remplace ${replacing.fullName}.',
    );
    if (!ok || !mounted) return;
    _reload();
    if (id != null &&
        await confirm(context, 'Visage', 'Enregistrer maintenant le visage de ${f.fullName} ?', ok: 'Oui')) {
      if (mounted && await enrollFaceFlow(context, store, id!, f.fullName)) _reload();
    }
  }

  /// Retire un membre sans le remplacer : il sort de l'équipe et des saisies, ses journées passées restent.
  /// Seul l'admin peut le réactiver ou supprimer sa fiche.
  Future<void> _remove(AppStore store, MyTeam team, WorkerInfo w) async {
    if (!await confirm(
      context,
      'Retirer ${w.fullName} ?',
      '${w.fullName} quittera l\'équipe ${team.name} et n\'apparaîtra plus dans les saisies. '
          'Ses journées passées restent enregistrées ; seul l\'admin pourra le réactiver.',
      ok: 'Retirer',
    )) {
      return;
    }
    if (!mounted) return;
    if (await run(context, () => store.repo.removeWorker(w.id), success: '${w.fullName} retiré de l\'équipe.')) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return AsyncBody(
      future: _future!,
      onRetry: _reload,
      builder: (context, d) {
        if (d.teams.isEmpty) {
          return const Center(
            child: Padding(padding: EdgeInsets.all(24), child: Text('Aucune équipe ne vous est confiée.')),
          );
        }
        final team = d.teams.firstWhere((t) => t.id == _teamId, orElse: () => d.teams.first);
        final members = d.workers.where((w) => w.teamId == team.id && w.active).toList();
        final withFace = members.where((w) => w.faceEnrolled).length;
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (d.teams.length > 1)
                DropdownButtonFormField<String>(
                  initialValue: team.id,
                  decoration: const InputDecoration(labelText: 'Équipe', prefixIcon: Icon(Icons.groups_outlined)),
                  items: [
                    for (final t in d.teams) DropdownMenuItem(value: t.id, child: Text('${t.name} (${t.relation})')),
                  ],
                  onChanged: (v) => setState(() => _teamId = v),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: StatTile(label: 'Membres enregistrés', value: '${members.length}', icon: Icons.groups),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: StatTile(
                      label: 'Visages enregistrés',
                      value: '$withFace / ${members.length}',
                      icon: Icons.face_retouching_natural,
                      color: withFace == members.length ? okColor : warnColor,
                    ),
                  ),
                ],
              ),
              if (members.isEmpty) ...[
                const SizedBox(height: 12),
                const InfoBanner(
                  icon: Icons.info_outline,
                  color: accent,
                  text: 'Première utilisation : enregistrez les membres de votre équipe un par un, avec leur visage.',
                ),
              ],
              SectionTitle(
                'Membres de ${team.name}',
                trailing: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                  onPressed: () => _add(store, team),
                  icon: const Icon(Icons.person_add_alt),
                  label: const Text('Ajouter'),
                ),
              ),
              GlassCard(
                child: Column(
                  children: [
                    if (members.isEmpty)
                      const Padding(padding: EdgeInsets.all(16), child: Text('Aucun membre enregistré.')),
                    for (final (i, w) in members.indexed) ...[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: (w.faceEnrolled ? okColor : warnColor).withValues(alpha: 0.15),
                          child: Icon(
                            w.faceEnrolled ? Icons.verified_user : Icons.face_outlined,
                            color: w.faceEnrolled ? okColor : warnColor,
                          ),
                        ),
                        title: Text(w.fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                          w.isSupervisor
                              ? 'Superviseur'
                              : w.faceEnrolled
                              ? 'Visage enregistré'
                              : 'Visage non enregistré',
                        ),
                        trailing: Wrap(
                          spacing: 4,
                          children: [
                            if (!w.faceEnrolled)
                              IconButton(
                                tooltip: 'Enregistrer le visage',
                                icon: const Icon(Icons.add_a_photo_outlined, color: accent),
                                onPressed: () async {
                                  if (await enrollFaceFlow(context, store, w.id, w.fullName)) _reload();
                                },
                              ),
                            if (!w.isSupervisor)
                              IconButton(
                                tooltip: 'Remplacer cet ouvrier',
                                icon: const Icon(Icons.swap_horiz, color: textMuted),
                                onPressed: () => _add(store, team, replacing: w),
                              ),
                            if (!w.isSupervisor)
                              IconButton(
                                tooltip: 'Retirer de l\'équipe',
                                icon: const Icon(Icons.person_remove_outlined, color: errColor),
                                onPressed: () => _remove(store, team, w),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Un visage déjà enregistré ne peut être refait que par l\'admin.',
                style: TextStyle(fontSize: 12, color: textMuted),
              ),
            ],
          ),
        );
      },
    );
  }
}
