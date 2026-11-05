import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import '../data/app_store.dart';
import 'glass.dart';
import 'widgets.dart';

/// « Mon compte » : changer son propre code PIN. Le même écran sert, sans retour possible, quand le code est
/// PROVISOIRE (création du compte ou réinitialisation par un admin) : il faut alors choisir son propre code avant
/// de continuer. Les autres connexions ouvertes avec l'ancien code sont fermées à ce moment-là.
class ChangePinScreen extends StatefulWidget {
  /// true = code provisoire : l'écran remplace toute l'application jusqu'au changement (seule sortie : se déconnecter).
  final bool forced;
  const ChangePinScreen({super.key, this.forced = false});

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
  final _key = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _show = false;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  static final _digits = RegExp(r'^\d{4,6}$');

  Future<void> _submit() async {
    if (!(_key.currentState?.validate() ?? false)) return;
    final store = StoreScope.of(context);
    setState(() => _busy = true);
    final ok = await run(context, () => store.changePin(_current.text, _new.text),
        success: widget.forced ? null : 'Code modifié. Les autres connexions ont été fermées.');
    if (!mounted) return;
    setState(() => _busy = false);
    // Écran « obligatoire » : l'application se met à jour toute seule ; sinon on revient à l'écran précédent.
    if (ok && !widget.forced) Navigator.of(context).pop();
  }

  Widget _field(TextEditingController c, String label, {String? Function(String?)? validator, TextInputAction? action}) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextFormField(
          controller: c,
          obscureText: !_show,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          textInputAction: action,
          decoration: InputDecoration(labelText: label, prefixIcon: const Icon(Icons.lock_outline)),
          validator: validator,
          onFieldSubmitted: action == TextInputAction.done ? (_) => _submit() : null,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final u = store.user!;
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: const GlassBar(child: SizedBox.expand()),
        automaticallyImplyLeading: !widget.forced,
        title: Text(widget.forced ? 'Choisissez votre code' : 'Mon compte'),
        actions: [
          if (widget.forced)
            IconButton(tooltip: 'Se déconnecter', icon: const Icon(Icons.logout), onPressed: store.logout),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: _key,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (widget.forced) ...[
                  const InfoBanner(
                    icon: Icons.lock_reset,
                    color: warnColor,
                    text: 'Votre code est provisoire. Choisissez votre propre code pour continuer : '
                        'lui seul vous donnera accès, personne d\'autre ne le connaîtra.',
                  ),
                  const SizedBox(height: 12),
                ],
                GlassCard(
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.person)),
                    title: Text(u.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(u.roleLabel),
                  ),
                ),
                const SizedBox(height: 8),
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(widget.forced ? 'Nouveau code' : 'Changer mon code PIN', style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text(
                        '4 à 6 chiffres, pas trop simple (évitez 0000, 1234, 1212…). '
                        'Vos autres connexions ouvertes avec l\'ancien code seront fermées.',
                        style: TextStyle(fontSize: 12, color: textMuted),
                      ),
                      _field(_current, widget.forced ? 'Code provisoire reçu' : 'Code actuel',
                          validator: (v) => (v ?? '').isEmpty ? 'Saisissez votre code actuel.' : null, action: TextInputAction.next),
                      _field(_new, 'Nouveau code',
                          validator: (v) => !_digits.hasMatch(v ?? '')
                              ? 'Le code doit contenir 4 à 6 chiffres.'
                              : (v == _current.text ? 'Le nouveau code doit être différent.' : null),
                          action: TextInputAction.next),
                      _field(_confirm, 'Confirmer le nouveau code',
                          validator: (v) => v != _new.text ? 'Les deux codes ne correspondent pas.' : null, action: TextInputAction.done),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() => _show = !_show),
                          icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                          label: Text(_show ? 'Masquer les codes' : 'Afficher les codes'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : _submit,
                          icon: const Icon(Icons.check),
                          label: Text(widget.forced ? 'Enregistrer et continuer' : 'Changer mon code'),
                        ),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ouvre « Mon compte » depuis n'importe quel écran (admin, président, superviseur).
Future<void> openAccount(BuildContext context, AppStore store) => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => StoreScope(store: store, child: const ChangePinScreen())));

/// Code PROVISOIRE affiché une seule fois à l'admin, qui le transmet à la personne. Celle-ci devra choisir
/// son propre code à sa prochaine connexion ; l'admin ne connaît donc jamais le code définitif.
Future<void> showTempPinDialog(BuildContext context, {required String name, required String pin}) => showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Code provisoire'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Nom : $name'),
          const SizedBox(height: 10),
          Center(
            child: SelectableText(pin,
                style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 6, fontFeatures: [FontFeature.tabularFigures()])),
          ),
          const SizedBox(height: 12),
          const Text(
            'Transmettez-lui ce code en main propre ou par message privé. Il ne sera plus affiché.\n\n'
            'À sa prochaine connexion, il devra choisir son propre code. '
            'Ses connexions en cours ont été fermées.',
            style: TextStyle(fontSize: 13),
          ),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: pin));
              if (ctx.mounted) toast(ctx, 'Code copié.');
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copier'),
          ),
          FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(100, 40)),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('J\'ai noté le code')),
        ],
      ),
    );
