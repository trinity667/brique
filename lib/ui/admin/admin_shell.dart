import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/app_store.dart';
import '../../domain/models.dart';
import '../account_screen.dart';
import '../glass.dart';
import '../supervisor/day_entry_view.dart';
import '../calendar_view.dart';
import 'alerts_screen.dart';
import 'audit_screen.dart';
import 'data_screen.dart';
import 'invoices_screen.dart';
import 'period_screen.dart';
import 'overview_screen.dart';
import 'payments_screen.dart';
import 'payroll_screen.dart';
import 'payroll_sheets_screen.dart';
import 'reports_screen.dart';
import 'stats_screen.dart';
import 'tariffs_screen.dart';
import 'teams_screen.dart';

class _Page {
  final String title;
  final IconData icon;
  final IconData selectedIcon;
  final Widget body;
  final String section;
  const _Page(this.title, this.icon, this.selectedIcon, this.body, this.section);
}

/// Dashboard admin, partagé par les responsables (droits vérifiés par le serveur).
/// - Téléphone : barre de navigation du bas (3 entrées) + menu « Plus ».
/// - Web / tablette (≥ 900 px) : barre latérale verte (sections), barre de titre, contenu centré.
/// La page « Rapports » n'existe que pour le président.
class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _tab = 0;

  static const wideBreakpoint = 900.0;

  static const _base = [
    _Page('Tableau de bord', Icons.dashboard_outlined, Icons.dashboard, OverviewScreen(), 'Pilotage'),
    _Page('Calendrier', Icons.calendar_month_outlined, Icons.calendar_month, _AdminCalendar(), 'Pilotage'),
    _Page('Équipes & superviseurs', Icons.groups_outlined, Icons.groups, TeamsScreen(), 'Pilotage'),
    _Page('Statistiques', Icons.insights_outlined, Icons.insights, StatsScreen(), 'Pilotage'),
    _Page('Paie mensuelle', Icons.calculate_outlined, Icons.calculate, PayrollScreen(), 'Paie & finances'),
    _Page('Alertes', Icons.notifications_outlined, Icons.notifications, AlertsScreen(), 'Pilotage'),
    _Page('Factures', Icons.receipt_long_outlined, Icons.receipt_long, InvoicesScreen(), 'Paie & finances'),
    _Page('Paie sur période', Icons.date_range_outlined, Icons.date_range, PeriodScreen(), 'Paie & finances'),
    _Page('Fiches de paie', Icons.assignment_outlined, Icons.assignment, PayrollSheetsScreen(), 'Paie & finances'),
    _Page('Paiements', Icons.payments_outlined, Icons.payments, PaymentsScreen(), 'Paie & finances'),
    _Page('Prix & tarifs', Icons.sell_outlined, Icons.sell, TariffsScreen(), 'Paie & finances'),
    _Page('Import & sauvegarde', Icons.cloud_sync_outlined, Icons.cloud_sync, DataScreen(), 'Administration'),
    _Page('Journal d\'audit', Icons.fact_check_outlined, Icons.fact_check, AuditScreen(), 'Administration'),
  ];

  static const _reports = _Page('Rapports', Icons.summarize_outlined, Icons.summarize, ReportsScreen(), 'Président');

  /// Le président voit « Rapports » juste après les 3 pages principales (1re entrée du menu « Plus »).
  List<_Page> _pagesFor(AppUser u) => u.isPresident ? [..._base.take(3), _reports, ..._base.skip(3)] : _base;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final pages = _pagesFor(store.user!);
    final tab = _tab.clamp(0, pages.length - 1);
    return LayoutBuilder(
      builder: (context, box) =>
          box.maxWidth >= wideBreakpoint ? _wide(store, pages, tab) : _compact(store, pages, tab),
    );
  }

  // ───────── Web / grand écran ─────────
  Widget _wide(AppStore store, List<_Page> pages, int tab) {
    final u = store.user!;
    // Ordre d'affichage par section, en gardant l'index réel de chaque page.
    const order = ['Président', 'Pilotage', 'Paie & finances', 'Administration'];
    final items = <Widget>[];
    for (final section in order) {
      final idx = [
        for (var i = 0; i < pages.length; i++)
          if (pages[i].section == section) i,
      ];
      if (idx.isEmpty) continue;
      items.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 18, 14, 6),
          child: Text(
            section.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 1.4,
              fontWeight: FontWeight.w800,
              color: Color(0xFFB7D3BF),
            ),
          ),
        ),
      );
      for (final i in idx) {
        items.add(_SideItem(page: pages[i], selected: i == tab, onTap: () => setState(() => _tab = i)));
      }
    }

    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 264,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF175232), accentDeep],
              ),
            ),
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 22, 18, 10),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            border: Border.all(color: gold, width: 1.5),
                          ),
                          child: Image.asset(
                            'assets/logo.png',
                            width: 46,
                            height: 46,
                            semanticLabel: 'Association Bayiir Mêtba',
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Briques & Paie',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Association Bayiir Mêtba',
                                style: TextStyle(fontSize: 11.5, color: Color(0xFFE9D8A6)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(color: Color(0x33FFFFFF), height: 16, indent: 18, endIndent: 18),
                  Expanded(
                    child: ListView(padding: const EdgeInsets.symmetric(horizontal: 10), children: items),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 17,
                            backgroundColor: gold,
                            child: Text(
                              u.name.isEmpty ? '?' : u.name[0].toUpperCase(),
                              style: const TextStyle(fontWeight: FontWeight.w800, color: accentDeep),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  u.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                                ),
                                Text(u.roleLabel, style: const TextStyle(fontSize: 12, color: Color(0xFFB7D3BF))),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Mon compte',
                            icon: const Icon(Icons.manage_accounts_outlined, size: 20, color: Colors.white70),
                            onPressed: () => openAccount(context, store),
                          ),
                          IconButton(
                            tooltip: 'Se déconnecter',
                            icon: const Icon(Icons.logout, size: 20, color: Colors.white70),
                            onPressed: store.logout,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 68,
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  decoration: const BoxDecoration(
                    color: panelSolid,
                    border: Border(bottom: BorderSide(color: lineColor)),
                  ),
                  child: Row(
                    children: [
                      Icon(pages[tab].selectedIcon, color: accent),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          pages[tab].title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.3,
                            color: textStrong,
                          ),
                        ),
                      ),
                      Text(fmtLongDate(DateTime.now()), style: const TextStyle(color: textMuted)),
                      if (u.isPresident) ...[
                        const SizedBox(width: 14),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: gold.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: gold),
                          ),
                          child: const Text(
                            'Président',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFF7A5F0A)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1280),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        // Une page à la fois : chaque onglet recharge ses données du serveur à l'ouverture.
                        child: KeyedSubtree(key: ValueKey(pages[tab].title), child: pages[tab].body),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ───────── Téléphone ─────────
  Widget _compact(AppStore store, List<_Page> pages, int tab) {
    final main = pages.take(3).toList();
    final more = pages.skip(3).toList();
    final isMore = tab >= 3;

    return Scaffold(
      appBar: AppBar(
        flexibleSpace: const GlassBar(child: SizedBox.expand()),
        title: Row(
          children: [
            Image.asset('assets/logo.png', width: 30, height: 30),
            const SizedBox(width: 10),
            Expanded(child: Text(isMore ? 'Plus' : pages[tab].title, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(tooltip: 'Mon compte', icon: const Icon(Icons.manage_accounts_outlined), onPressed: () => openAccount(context, store)),
          IconButton(tooltip: 'Se déconnecter', icon: const Icon(Icons.logout), onPressed: store.logout),
        ],
      ),
      body: isMore
          ? _MoreList(store: store, pages: more)
          : KeyedSubtree(key: ValueKey(pages[tab].title), child: pages[tab].body),
      bottomNavigationBar: GlassBar(
        child: NavigationBar(
          selectedIndex: isMore ? 3 : tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: [
            for (final p in main)
              NavigationDestination(
                icon: Icon(p.icon),
                selectedIcon: Icon(p.selectedIcon),
                label: p.title.split(' ').first,
              ),
            const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'Plus'),
          ],
        ),
      ),
    );
  }
}

class _SideItem extends StatelessWidget {
  final _Page page;
  final bool selected;
  final VoidCallback onTap;
  const _SideItem({required this.page, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1.5),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: selected ? Colors.white : null),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 18,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: selected ? gold : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Icon(selected ? page.selectedIcon : page.icon, color: selected ? accent : Colors.white70, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  page.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                    color: selected ? accentDeep : Colors.white.withValues(alpha: 0.88),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MoreList extends StatelessWidget {
  final AppStore store;
  final List<_Page> pages;
  const _MoreList({required this.store, required this.pages});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final p in pages) ...[
          GlassCard(
            child: ListTile(
              leading: Icon(p.selectedIcon, color: accent),
              title: Text(p.title, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(p.section),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => StoreScope(
                    store: store,
                    child: Scaffold(
                      appBar: AppBar(
                        flexibleSpace: const GlassBar(child: SizedBox.expand()),
                        title: Text(p.title),
                      ),
                      body: p.body,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        Text('Connecté : ${store.user!.name} · ${store.user!.roleLabel}', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// Calendrier admin : un clic sur « Ouvrir la saisie » ouvre la journée de l'équipe pour correction.
class _AdminCalendar extends StatelessWidget {
  const _AdminCalendar();

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return CalendarView(
      isAdmin: true,
      onOpenDay: (date, teamId, teamName) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => StoreScope(
            store: store,
            child: Scaffold(
              appBar: AppBar(
                flexibleSpace: const GlassBar(child: SizedBox.expand()),
                title: Text(teamName),
              ),
              body: DayEntryView(initialDate: date, initialTeamId: teamId, initialTeamName: teamName),
            ),
          ),
        ),
      ),
    );
  }
}
