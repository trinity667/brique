import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../data/api_client.dart';
import '../../data/app_store.dart';
import '../../domain/models.dart';
import '../account_screen.dart';
import '../face_enroll.dart';
import '../glass.dart';
import 'worker_sheet_screen.dart';
import '../widgets.dart';
import 'worker_form.dart';

class _TeamsData {
  final List<TeamInfo> teams;
  final List<WorkerInfo> workers;
  final List<SupervisorInfo> supervisors;
  /// Comptes des administrateurs : chargés pour le président seulement (null pour les autres admins).
  final List<AdminAccount>? admins;
  const _TeamsData(this.teams, this.workers, this.supervisors, [this.admins]);
}

/// Équipes, membres, superviseurs, remplacement d'un superviseur et enregistrement des visages.
class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key});

  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  Future<_TeamsData>? _future;

  Future<_TeamsData> _fetch() async {
    final store = StoreScope.of(context);
    final r = store.repo;
    final president = store.user?.isPresident ?? false;
    final all = await Future.wait([r.teams(), r.workers(), r.supervisors()]);
    List<AdminAccount>? admins;
    if (president) {
      try {
        admins = await r.admins();
      } on ApiException {/* la liste des admins reste masquée */}
    }
    return _TeamsData(all[0] as List<TeamInfo>, all[1] as List<WorkerInfo>, all[2] as List<SupervisorInfo>, admins);
  }

  void _reload() {
    // Bloc (et non « => ») : setState refuse un callback qui renvoie un Future.
    final next = _fetch();
    setState(() {
      _future = next;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return Scaffold(
      body: AsyncBody<_TeamsData>(
        future: _future!,
        onRetry: _reload,
        builder: (context, d) => ListView(padding: const EdgeInsets.all(16), children: [
          if (d.teams.isEmpty)
            const InfoBanner(
                icon: Icons.groups,
                color: accent,
                text: 'Commencez par créer une équipe, puis ajoutez ses membres (10 ouvriers) '
                    'et désignez le superviseur parmi eux.'),
          for (final t in d.teams) ...[_teamCard(context, store, d, t), const SizedBox(height: 10)],
          ..._formerWorkers(context, store, d),
          const SectionTitle('Superviseurs enregistrés'),
          GlassCard(
            child: d.supervisors.isEmpty
                ? const Padding(padding: EdgeInsets.all(16), child: Text('Aucun superviseur.'))
                : Column(children: [
                    for (final u in d.supervisors)
                      ListTile(
                        leading: const Icon(Icons.badge),
                        title: Text(u.name),
                        subtitle: Text([
                          ...u.chiefOf.map((t) => 'Titulaire de $t'),
                          ...u.interimOf.map((t) => 'Remplaçant sur $t'),
                          if (!u.active) 'Désactivé',
                          if (u.mustChangePin) 'Code provisoire à changer',
                        ].join(' · ')),
                        trailing: _accountMenu(
                          context,
                          name: u.name,
                          active: u.active,
                          onReset: () => store.repo.resetSupervisorPin(u.id),
                          onRename: (n) => store.repo.updateSupervisor(u.id, name: n),
                          onActive: (a) => store.repo.updateSupervisor(u.id, active: a),
                        ),
                      ),
                  ]),
          ),
          if (d.admins != null) ...[
            const SectionTitle('Administrateurs'),
            GlassCard(
              child: Column(children: [
                for (final a in d.admins!)
                  ListTile(
                    leading: Icon(a.isPresident ? Icons.workspace_premium : Icons.admin_panel_settings_outlined),
                    title: Text(a.name),
                    subtitle: Text([
                      a.isPresident ? 'Président' : 'Administrateur',
                      if (!a.active) 'Désactivé',
                      if (a.mustChangePin) 'Code provisoire à changer',
                      if (store.user?.id == a.id) 'vous',
                    ].join(' · ')),
                    // Le président ne se modifie pas ici (son code se change dans « Mon compte », se récupère sur le serveur).
                    trailing: a.isPresident || store.user?.id == a.id
                        ? null
                        : _accountMenu(
                            context,
                            name: a.name,
                            active: a.active,
                            onReset: () => store.repo.resetAdminPin(a.id),
                            onRename: (n) => store.repo.updateAdmin(a.id, name: n),
                            onActive: (v) => store.repo.updateAdmin(a.id, active: v),
                          ),
                  ),
              ]),
            ),
          ],
          const SizedBox(height: 90),
        ]),
      ),
      floatingActionButton: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        FloatingActionButton.extended(
          heroTag: 'sup',
          onPressed: () => _createSupervisor(context, store),
          icon: const Icon(Icons.person_add),
          label: const Text('Superviseur'),
        ),
        const SizedBox(height: 10),
        FloatingActionButton.extended(
          heroTag: 'team',
          onPressed: () async {
            final n = await askText(context, title: 'Nouvelle équipe', label: 'Nom');
            if (n != null && context.mounted && await run(context, () => store.repo.createTeam(n), success: 'Équipe créée.')) {
              _reload();
            }
          },
          icon: const Icon(Icons.add),
          label: const Text('Équipe'),
        ),
      ]),
    );
  }

  Widget _teamCard(BuildContext context, AppStore store, _TeamsData d, TeamInfo t) {
    final members = d.workers.where((w) => w.teamId == t.id && w.active).toList();
    return GlassCard(
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const CircleAvatar(child: Icon(Icons.groups)),
        title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('Superviseur : ${t.chief?.name ?? 'non affecté'}\n${t.members} membre(s) · Poste de ${t.shift}'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (t.interim != null)
            InfoBanner(
                icon: Icons.swap_horiz,
                color: accent,
                text: 'Remplacement en cours : ${t.interim!.name} (connexion avec son propre PIN).'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Poste de travail'),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'jour', label: Text('Jour'), icon: Icon(Icons.wb_sunny_outlined, size: 18)),
                  ButtonSegment(value: 'nuit', label: Text('Nuit'), icon: Icon(Icons.nightlight_outlined, size: 18)),
                ],
                selected: {t.shift},
                onSelectionChanged: (s) async {
                  if (await run(context, () => store.repo.setTeamShift(t.id, s.first), success: 'Poste enregistré.')) {
                    _reload();
                  }
                },
              ),
            ]),
          ),
          Wrap(spacing: 8, children: [
            TextButton.icon(
              icon: const Icon(Icons.manage_accounts),
              label: const Text('Titulaire'),
              onPressed: () => _pick(context, store, d, t, interim: false),
            ),
            TextButton.icon(
              icon: const Icon(Icons.swap_horiz),
              label: Text(t.interim == null ? 'Désigner un remplaçant' : 'Changer le remplaçant'),
              onPressed: () => _pick(context, store, d, t, interim: true),
            ),
            if (t.interim != null)
              TextButton.icon(
                icon: const Icon(Icons.undo),
                label: const Text('Fin du remplacement'),
                onPressed: () async {
                  if (await run(context, () => store.repo.setInterim(t.id, null), success: 'Remplacement terminé.')) _reload();
                },
              ),
          ]),
          const Divider(),
          for (final w in members)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(w.fullName),
              onTap: () => _openSheet(context, store, w),
              isThreeLine: _contactText(w) != null,
              subtitle: Text(_memberSubtitle(w)),
              trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                IconButton(
                  tooltip: 'Coordonnées',
                  icon: const Icon(Icons.contact_phone_outlined, size: 20),
                  onPressed: () => _editContact(context, store, w),
                ),
                TextButton.icon(
                  icon: Icon(w.faceEnrolled ? Icons.refresh : Icons.face_retouching_natural, size: 18),
                  label: Text(w.faceEnrolled ? 'Refaire' : 'Enregistrer'),
                  onPressed: () => _enroll(context, store, w),
                ),
                if (w.faceEnrolled)
                  IconButton(
                    tooltip: 'Supprimer le visage (retrait du consentement)',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () async {
                      if (await confirm(context, 'Supprimer le visage ?',
                              'La signature faciale de ${w.fullName} sera effacée.', ok: 'Supprimer') &&
                          context.mounted &&
                          await run(context, () => store.repo.deleteFace(w.id), success: 'Visage supprimé.')) {
                        _reload();
                      }
                    },
                  ),
              ]),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Ajouter un membre'),
              onPressed: () async {
                final f = await showWorkerForm(context);
                if (f != null && context.mounted &&
                    await run(
                        context,
                        () => store.repo.addWorker(
                            fullName: f.fullName,
                            teamId: t.id,
                            phone: f.phone,
                            village: f.village,
                            cnib: f.cnib,
                            mobileOperator: f.mobileOperator,
                            mobileNumber: f.mobileNumber),
                        success: 'Ouvrier enregistré.')) {
                  _reload();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  /// Fiche de l'ouvrier ; elle renvoie true quand il a été retiré, supprimé ou réactivé (la liste se recharge).
  Future<void> _openSheet(BuildContext context, AppStore store, WorkerInfo w) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
        builder: (_) => StoreScope(store: store, child: WorkerSheetScreen(workerId: w.id, name: w.fullName))));
    if (changed == true && mounted) _reload();
  }

  /// Ouvriers retirés (hors superviseurs) : on ouvre leur fiche, ou on les réactive d'un geste.
  List<Widget> _formerWorkers(BuildContext context, AppStore store, _TeamsData d) {
    final former = d.workers.where((w) => !w.active && !w.isSupervisor).toList();
    if (former.isEmpty) return const [];
    return [
      GlassCard(
        child: ExpansionTile(
          shape: const Border(),
          collapsedShape: const Border(),
          leading: const CircleAvatar(child: Icon(Icons.person_off_outlined)),
          title: const Text('Anciens ouvriers', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text('${former.length} retiré(s) · historique conservé'),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          children: [
            for (final w in former)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(w.fullName),
                subtitle: Text(w.teamName == null ? 'Sans équipe' : 'Ancienne équipe : ${w.teamName}'),
                onTap: () => _openSheet(context, store, w),
                trailing: TextButton.icon(
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('Réactiver'),
                  onPressed: () async {
                    if (await run(context, () => store.repo.updateWorker(w.id, active: true), success: 'Ouvrier réactivé.')) _reload();
                  },
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 10),
    ];
  }

  static String? _contactText(WorkerInfo w) {
    final parts = [
      if (w.phone != null) w.phone!,
      if (w.village != null) w.village!,
      if (w.mobileOperator != null && w.mobileNumber != null)
        '${mobileOperators[w.mobileOperator] ?? w.mobileOperator} ${w.mobileNumber}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _memberSubtitle(WorkerInfo w) {
    final face = w.faceEnrolled ? 'Visage enregistré' : 'Visage non enregistré';
    final contact = _contactText(w);
    return contact == null ? face : '$face\n$contact';
  }

  Future<void> _editContact(BuildContext context, AppStore store, WorkerInfo w) async {
    final f = await showWorkerForm(context, existing: w);
    if (f == null || !context.mounted) return;
    final ok = await run(
        context,
        () => store.repo.updateContact(w.id,
            fullName: f.fullName,
            phone: f.phone,
            village: f.village,
            cnib: f.cnib,
            mobileOperator: f.mobileOperator,
            mobileNumber: f.mobileNumber),
        success: 'Coordonnées enregistrées.');
    if (ok) _reload();
  }

  /// Enregistrement du visage : 3 photos, le serveur calcule et chiffre la signature puis jette les photos.
  Future<void> _enroll(BuildContext context, AppStore store, WorkerInfo w) async {
    if (await enrollFaceFlow(context, store, w.id, w.fullName)) _reload();
  }

  Future<void> _pick(BuildContext context, AppStore store, _TeamsData d, TeamInfo t, {required bool interim}) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(interim ? 'Remplaçant de ${t.name}' : 'Titulaire de ${t.name}'),
        children: [
          if (d.supervisors.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('Créez d\'abord un superviseur.')),
          for (final c in d.supervisors.where((s) => s.active))
            SimpleDialogOption(onPressed: () => Navigator.pop(ctx, c.id), child: Text(c.name)),
        ],
      ),
    );
    if (picked == null || !context.mounted) return;
    final ok = await run(context,
        () => interim ? store.repo.setInterim(t.id, picked) : store.repo.setChief(t.id, picked),
        success: 'Affectation enregistrée.');
    if (ok) _reload();
  }

  /// Menu d'un compte (superviseur ou admin) : réinitialiser le code, renommer, désactiver / réactiver.
  /// Le serveur contrôle les droits et refuse ce qui n'est pas permis.
  Widget _accountMenu(
    BuildContext context, {
    required String name,
    required bool active,
    required Future<String> Function() onReset,
    required Future<void> Function(String name) onRename,
    required Future<void> Function(bool active) onActive,
  }) =>
      PopupMenuButton<String>(
        tooltip: 'Modifier le compte',
        onSelected: (v) async {
          if (v == 'reset') {
            if (!await confirm(
                context,
                'Réinitialiser le code de $name ?',
                'Un code provisoire sera généré et affiché une seule fois. Ses connexions en cours seront fermées ; '
                    'il devra choisir son propre code à sa prochaine connexion.',
                ok: 'Réinitialiser')) {
              return;
            }
            if (!context.mounted) return;
            String? pin;
            if (await run(context, () async => pin = await onReset()) && context.mounted) {
              _reload();
              await showTempPinDialog(context, name: name, pin: pin!);
            }
          } else if (v == 'rename') {
            final n = await askText(context, title: 'Renommer $name', label: 'Nouveau nom (sert à la connexion)');
            if (n == null || n.trim().length < 2 || !context.mounted) return;
            if (await run(context, () => onRename(n.trim()), success: 'Compte renommé.')) _reload();
          } else {
            if (!await confirm(
                context,
                active ? 'Désactiver le compte de $name ?' : 'Réactiver le compte de $name ?',
                active ? 'Il ne pourra plus se connecter, tout de suite. Son historique est conservé.' : 'Il pourra de nouveau se connecter.',
                ok: active ? 'Désactiver' : 'Réactiver')) {
              return;
            }
            if (!context.mounted) return;
            if (await run(context, () => onActive(!active), success: active ? 'Compte désactivé.' : 'Compte réactivé.')) _reload();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'reset', child: ListTile(leading: Icon(Icons.lock_reset), title: Text('Réinitialiser le code'), dense: true)),
          const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('Renommer'), dense: true)),
          PopupMenuItem(
              value: 'active',
              child: ListTile(
                  leading: Icon(active ? Icons.block : Icons.check_circle_outline),
                  title: Text(active ? 'Désactiver' : 'Réactiver'),
                  dense: true)),
        ],
      );

  Future<void> _createSupervisor(BuildContext context, AppStore store) async {
    List<WorkerInfo> workers;
    try {
      workers = (await store.repo.workers()).where((w) => w.active && !w.isSupervisor).toList()
        ..sort((a, b) => a.fullName.compareTo(b.fullName));
    } catch (_) {
      if (context.mounted) toast(context, 'Impossible de charger les ouvriers.', error: true);
      return;
    }
    if (!context.mounted) return;
    final pin = TextEditingController();
    String? workerId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nouveau superviseur'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('Le superviseur est l\'un des ouvriers. Il reste dans son équipe.'),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Ouvrier'),
              items: [
                for (final w in workers)
                  DropdownMenuItem(
                      value: w.id,
                      child: Text('${w.fullName} · ${w.teamName ?? '—'}', overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => workerId = v,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(labelText: 'Code provisoire (4 à 6 chiffres)'),
            ),
            const SizedBox(height: 4),
            const Text(
              'Le superviseur devra choisir son propre code à sa première connexion.',
              style: TextStyle(fontSize: 12, color: textMuted),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 40)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Créer'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (workerId == null) {
      toast(context, 'Choisissez un ouvrier.', error: true);
      return;
    }
    final name = workers.firstWhere((w) => w.id == workerId).fullName;
    if (await run(context, () => store.repo.createSupervisor(workerId!, pin.text)) && context.mounted) {
      _reload();
      await showTempPinDialog(context, name: name, pin: pin.text);
    }
  }
}
