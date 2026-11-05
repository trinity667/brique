import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/app_store.dart';
import '../../domain/models.dart';
import '../glass.dart';
import '../widgets.dart';

Color _levelColor(String level) => switch (level) {
      'high' => errColor,
      'medium' => warnColor,
      _ => accentSoft,
    };

IconData _levelIcon(String level) => switch (level) {
      'high' => Icons.error_outline,
      'medium' => Icons.warning_amber_rounded,
      _ => Icons.info_outline,
    };

/// Alertes de l'admin : jours sans saisie, journées incomplètes, baisse de production,
/// absences répétées, paie à valider, avances excessives, prix manquants…
/// Elles sont calculées à la demande : on ne les supprime pas, on les **ignore** (commun à tous les admins).
/// Une alerte ignorée disparaît de la liste et revient d'elle-même si la situation change ; on peut aussi la rétablir.
/// La liste s'actualise seule toutes les 90 secondes, avec le bouton ↻ ou en tirant vers le bas.
class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key});

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  Future<AlertsView>? _future;
  Future<AlertsView>? _ignored;
  bool _showIgnored = false;
  bool _busy = false;
  DateTime? _updated;
  Timer? _timer;

  Future<AlertsView> _fetch() async {
    final v = await StoreScope.of(context).repo.alerts();
    if (mounted) setState(() => _updated = DateTime.now());
    return v;
  }

  void _reload() {
    final repo = StoreScope.of(context).repo;
    final next = _fetch();
    final ignored = _showIgnored ? repo.alerts(dismissed: true) : null;
    setState(() {
      _future = next;
      _ignored = ignored;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future == null) {
      _future = _fetch();
      _timer = Timer.periodic(const Duration(seconds: 90), (_) {
        if (mounted && !_busy) _reload();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Ignorer / rétablir : le serveur reste l'arbitre ; la liste est rechargée ensuite.
  Future<void> _act(Future<void> Function() action, {String? success}) async {
    setState(() => _busy = true);
    final ok = await run(context, action, success: success);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) _reload();
  }

  /// Règles réglables : briques attendues par sac de ciment (± tolérance) et objectif de production par jour.
  /// Une règle vide est désactivée : l'alerte correspondante n'existe pas.
  Future<void> _editRules() async {
    final repo = StoreScope.of(context).repo;
    late final AlertRules current;
    if (!await run(context, () async => current = await repo.alertRules()) || !mounted) return;
    final bag = TextEditingController(text: current.bricksPerBag?.toString() ?? '');
    final tol = TextEditingController(text: current.tolerancePct.toString());
    final target = TextEditingController(text: current.dailyTarget?.toString() ?? '');
    Widget field(TextEditingController c, String label, String hint) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(labelText: label, hintText: hint),
          ),
        );
    final saved = await showDialog<AlertRules>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Règles d'alerte"),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'Laissez un champ vide pour désactiver la règle.',
                style: TextStyle(fontSize: 13, color: textMuted),
              ),
              field(bag, 'Briques attendues par sac de ciment', 'ex. 95'),
              field(tol, 'Écart toléré (%)', 'ex. 20'),
              field(target, 'Objectif de briques par jour et par équipe', 'ex. 800'),
              const SizedBox(height: 10),
              const Text(
                "Ciment : alerte si une journée s'écarte de la valeur attendue (erreur de saisie, ciment ou briques à vérifier). "
                "Objectif : alerte si une équipe reste sous l'objectif au moins 3 jours sur 7.",
                style: TextStyle(fontSize: 12, color: textMuted),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 40)),
            onPressed: () => Navigator.pop(
              ctx,
              AlertRules(
                bricksPerBag: int.tryParse(bag.text),
                tolerancePct: int.tryParse(tol.text) ?? 20,
                dailyTarget: int.tryParse(target.text),
              ),
            ),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (saved != null && mounted && await run(context, () => repo.saveAlertRules(saved), success: 'Règles enregistrées.')) _reload();
  }

  void _toggleIgnored() {
    setState(() {
      _showIgnored = !_showIgnored;
      _ignored = _showIgnored ? StoreScope.of(context).repo.alerts(dismissed: true) : null;
    });
  }

  Widget _card(AlertItem a, {required String actionLabel, required IconData actionIcon, required VoidCallback? onAction, bool muted = false}) {
    final color = muted ? textMuted : _levelColor(a.level);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(_levelIcon(a.level), color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.title, style: TextStyle(fontWeight: FontWeight.w700, color: muted ? textMuted : null)),
              const SizedBox(height: 2),
              Text(a.detail, style: const TextStyle(color: textMuted)),
            ]),
          ),
          IconButton(tooltip: actionLabel, icon: Icon(actionIcon, size: 20), onPressed: onAction),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = StoreScope.of(context).repo;
    return AsyncBody<AlertsView>(
      future: _future!,
      onRetry: _reload,
      builder: (context, v) => RefreshIndicator(
        onRefresh: () async {
          _reload();
          await _future;
        },
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            Expanded(
              child: Text(
                v.count == 0
                    ? 'Aucune alerte'
                    : '${v.count} alerte${v.count > 1 ? 's' : ''}${v.high > 0 ? ' · ${v.high} urgente${v.high > 1 ? 's' : ''}' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
            ),
            IconButton(tooltip: "Règles d'alerte (ciment, objectif)", icon: const Icon(Icons.tune), onPressed: _busy ? null : _editRules),
            IconButton(tooltip: 'Actualiser', icon: const Icon(Icons.refresh), onPressed: _busy ? null : _reload),
          ]),
          if (_updated != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Mis à jour à ${two(_updated!.hour)}:${two(_updated!.minute)}',
                  style: const TextStyle(fontSize: 12, color: textMuted)),
            ),
          if (v.alerts.isEmpty)
            const InfoBanner(icon: Icons.check_circle, color: okColor, text: 'Rien à signaler pour le moment.')
          else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _busy ? null : () => _act(() => repo.dismissAlerts(), success: 'Alertes ignorées.'),
                icon: const Icon(Icons.done_all, size: 18),
                label: const Text('Tout ignorer'),
              ),
            ),
            for (final a in v.alerts)
              _card(a,
                  actionLabel: 'Ignorer cette alerte',
                  actionIcon: Icons.close,
                  onAction: _busy ? null : () => _act(() => repo.dismissAlerts(ids: [a.id]))),
          ],
          if (v.dismissedCount > 0 || _showIgnored)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _toggleIgnored,
                icon: Icon(_showIgnored ? Icons.expand_less : Icons.expand_more, size: 18),
                label: Text(_showIgnored ? 'Masquer les alertes ignorées' : 'Alertes ignorées (${v.dismissedCount})'),
              ),
            ),
          if (_showIgnored)
            FutureBuilder<AlertsView>(
              future: _ignored,
              builder: (context, snap) {
                final ig = snap.data;
                if (ig == null) {
                  return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()));
                }
                if (ig.alerts.isEmpty) {
                  return const Padding(padding: EdgeInsets.all(8), child: Text('Aucune alerte ignorée.', style: TextStyle(color: textMuted)));
                }
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text(
                    'Elles ne s\'affichent plus, mais reviennent d\'elles-mêmes si la situation change.',
                    style: TextStyle(fontSize: 12, color: textMuted),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _busy ? null : () => _act(() => repo.restoreAlerts(), success: 'Alertes rétablies.'),
                      icon: const Icon(Icons.undo, size: 18),
                      label: const Text('Tout rétablir'),
                    ),
                  ),
                  for (final a in ig.alerts)
                    _card(a,
                        muted: true,
                        actionLabel: 'Rétablir cette alerte',
                        actionIcon: Icons.undo,
                        onAction: _busy ? null : () => _act(() => repo.restoreAlerts(ids: [a.id]))),
                ]);
              },
            ),
        ]),
      ),
    );
  }
}

/// Bandeau du tableau de bord : nombre d'alertes (dont urgentes), ouvre la liste. Silencieux en cas d'erreur.
/// Se remet à jour quand [refreshToken] change (le tableau de bord l'incrémente à chaque actualisation) et
/// au retour de la liste des alertes (après en avoir ignoré, par exemple).
class AlertsBanner extends StatefulWidget {
  final int refreshToken;
  const AlertsBanner({super.key, this.refreshToken = 0});

  @override
  State<AlertsBanner> createState() => _AlertsBannerState();
}

class _AlertsBannerState extends State<AlertsBanner> {
  Future<AlertsView>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= StoreScope.of(context).repo.alerts();
  }

  @override
  void didUpdateWidget(AlertsBanner old) {
    super.didUpdateWidget(old);
    // L'ancien affichage reste en place pendant le rechargement (pas de clignotement).
    if (old.refreshToken != widget.refreshToken) _future = StoreScope.of(context).repo.alerts();
  }

  Future<void> _open(AppStore store) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => StoreScope(
            store: store,
            child: Scaffold(
              appBar: AppBar(flexibleSpace: const GlassBar(child: SizedBox.expand()), title: const Text('Alertes')),
              body: const AlertsScreen(),
            ))));
    if (mounted) setState(() => _future = store.repo.alerts());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AlertsView>(
      future: _future,
      builder: (context, snap) {
        final v = snap.data;
        if (v == null || v.count == 0) return const SizedBox.shrink();
        final color = v.high > 0 ? errColor : warnColor;
        final store = StoreScope.of(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _open(store),
            child: InfoBanner(
              icon: v.high > 0 ? Icons.error_outline : Icons.warning_amber_rounded,
              color: color,
              text: '${v.count} alerte${v.count > 1 ? 's' : ''}'
                  '${v.high > 0 ? ' dont ${v.high} urgente${v.high > 1 ? 's' : ''}' : ''} · toucher pour voir',
            ),
          ),
        );
      },
    );
  }
}
