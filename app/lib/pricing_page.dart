import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_state.dart';
import 'models.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Pricing data
// ─────────────────────────────────────────────────────────────────────────────

class _Tier {
  const _Tier({
    required this.name,
    required this.price,
    required this.period,
    required this.storage,
    required this.slug,
    required this.color,
    required this.icon,
    required this.features,
    this.highlighted = false,
    this.isFree = false,
  });

  final String name;
  final String price;
  final String period;
  final String storage;
  final String slug;
  final Color color;
  final IconData icon;
  final List<String> features;
  final bool highlighted;
  final bool isFree;
}

const _tiers = [
  _Tier(
    name: 'Free',
    price: '€0',
    period: 'forever',
    storage: '50 MB',
    slug: '',
    color: Color(0xFF607D8B),
    icon: Icons.lock_open_outlined,
    isFree: true,
    features: [
      '50 MB encrypted vault',
      'Unlimited conversations',
      'Full-text search',
      'People & relations graph',
      'Import from files',
      'On-device OCR',
    ],
  ),
  _Tier(
    name: 'Premium',
    price: '€4.99',
    period: '/ month',
    storage: '10 GB',
    slug: 'premium',
    color: Color(0xFF5C6BC0),
    icon: Icons.star_outline_rounded,
    features: [
      '10 GB encrypted vault',
      'Everything in Free',
      'Image capture & gallery',
      'Cross-device sync priority',
      'Export to PDF / JSON',
      'Email support',
    ],
  ),
  _Tier(
    name: 'Premium+',
    price: '€19.99',
    period: '/ month',
    storage: '100 GB',
    slug: 'premium-plus',
    color: Color(0xFF7B1FA2),
    icon: Icons.workspace_premium_rounded,
    highlighted: true,
    features: [
      '100 GB encrypted vault',
      'Everything in Premium',
      'Priority processing queue',
      'Advanced AI insights',
      'Custom relation types',
      'Dedicated support',
    ],
  ),
];

// ─────────────────────────────────────────────────────────────────────────────
//  PricingPage
// ─────────────────────────────────────────────────────────────────────────────

class PricingPage extends StatefulWidget {
  const PricingPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends State<PricingPage> {
  bool _loading = false;
  String? _error;

  String get _currentPlan => widget.state.quotaStatus?.plan ?? 'Free';

  Future<void> _checkout(String slug) async {
    if (slug.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final url = await widget.state.checkoutUrl(slug);
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        setState(() => _error = 'Could not open checkout URL.');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final quota = widget.state.quotaStatus;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 80),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1060),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Header ─────────────────────────────────────────────────────
              Icon(Icons.lock_outlined, size: 48, color: cs.primary),
              const SizedBox(height: 12),
              Text(
                'Your vault, your data.',
                style: tt.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'End-to-end encrypted. Pick the storage tier that fits you.',
                style: tt.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),

              // ── Current plan badge ─────────────────────────────────────────
              if (quota != null) ...[
                const SizedBox(height: 16),
                _CurrentPlanBadge(quota: quota),
              ],

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: cs.error),
                  textAlign: TextAlign.center,
                ),
              ],

              const SizedBox(height: 32),

              // ── Tier cards ─────────────────────────────────────────────────
              LayoutBuilder(
                builder: (ctx, constraints) {
                  final wide = constraints.maxWidth >= 700;
                  if (wide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final tier in _tiers) ...[
                          if (tier != _tiers.first) const SizedBox(width: 16),
                          Expanded(
                            child: _TierCard(
                              tier: tier,
                              isCurrentPlan: _matchesPlan(tier),
                              loading: _loading,
                              onUpgrade: () => _checkout(tier.slug),
                            ),
                          ),
                        ],
                      ],
                    );
                  }
                  return Column(
                    children: [
                      for (final tier in _tiers) ...[
                        if (tier != _tiers.first) const SizedBox(height: 16),
                        _TierCard(
                          tier: tier,
                          isCurrentPlan: _matchesPlan(tier),
                          loading: _loading,
                          onUpgrade: () => _checkout(tier.slug),
                        ),
                      ],
                    ],
                  );
                },
              ),

              const SizedBox(height: 40),

              // ── Feature comparison table ───────────────────────────────────
              const _ComparisonTable(),

              const SizedBox(height: 40),

              // ── FAQ ────────────────────────────────────────────────────────
              const _FaqSection(),

              const SizedBox(height: 32),
              Text(
                'All plans include end-to-end encryption, offline access, and no ads — ever.',
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _matchesPlan(_Tier tier) {
    if (tier.isFree) return _currentPlan == 'Free';
    if (tier.slug == 'premium') return _currentPlan == 'Premium';
    if (tier.slug == 'premium-plus') return _currentPlan == 'Premium+';
    return false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Current plan badge
// ─────────────────────────────────────────────────────────────────────────────

class _CurrentPlanBadge extends StatelessWidget {
  const _CurrentPlanBadge({required this.quota});
  final QuotaStatus quota;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final used = quota.usedPercent.clamp(0.0, 100.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.storage_outlined, size: 20, color: cs.primary),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Current plan: ${quota.plan}',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: 220,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: used / 100,
                      minHeight: 6,
                      color: used >= 100
                          ? cs.error
                          : used >= 80
                          ? Colors.orange
                          : cs.primary,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${quota.usedFormatted} of ${quota.limitFormatted} used',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Tier card
// ─────────────────────────────────────────────────────────────────────────────

class _TierCard extends StatelessWidget {
  const _TierCard({
    required this.tier,
    required this.isCurrentPlan,
    required this.loading,
    required this.onUpgrade,
  });

  final _Tier tier;
  final bool isCurrentPlan;
  final bool loading;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final highlight = tier.highlighted;
    final cardColor = highlight
        ? (isDark ? tier.color.withAlpha(50) : tier.color.withAlpha(18))
        : cs.surfaceContainerLow;
    final borderColor = highlight ? tier.color : cs.outlineVariant;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: highlight ? 2 : 1),
        boxShadow: highlight
            ? [
                BoxShadow(
                  color: tier.color.withAlpha(60),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Badge row ─────────────────────────────────────
            Row(
              children: [
                Icon(tier.icon, color: tier.color, size: 28),
                const Spacer(),
                if (highlight)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: tier.color,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'MOST POPULAR',
                      style: tt.labelSmall?.copyWith(
                        color: Colors.white,
                        letterSpacing: 0.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (isCurrentPlan)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'CURRENT',
                      style: tt.labelSmall?.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Name & price ──────────────────────────────────
            Text(
              tier.name,
              style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  tier.price,
                  style: tt.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: tier.color,
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    tier.period,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  Icons.storage_rounded,
                  size: 14,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '${tier.storage} vault storage',
                  style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),

            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),

            // ── Features list ─────────────────────────────────
            for (final f in tier.features) ...[
              _FeatureRow(text: f, color: tier.color),
              const SizedBox(height: 8),
            ],

            const SizedBox(height: 20),

            // ── CTA button ────────────────────────────────────
            SizedBox(
              width: double.infinity,
              child: tier.isFree
                  ? OutlinedButton(
                      onPressed: null,
                      child: Text(
                        isCurrentPlan ? 'Your current plan' : 'Free forever',
                      ),
                    )
                  : isCurrentPlan
                  ? FilledButton.tonal(
                      onPressed: null,
                      style: FilledButton.styleFrom(
                        backgroundColor: tier.color.withAlpha(30),
                        foregroundColor: tier.color,
                      ),
                      child: const Text('Active'),
                    )
                  : FilledButton(
                      onPressed: loading ? null : onUpgrade,
                      style: FilledButton.styleFrom(
                        backgroundColor: tier.color,
                        foregroundColor: Colors.white,
                      ),
                      child: loading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text('Upgrade to ${tier.name}'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.check_circle_outline_rounded, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Feature comparison table
// ─────────────────────────────────────────────────────────────────────────────

class _ComparisonTable extends StatelessWidget {
  const _ComparisonTable();

  final _rows = const [
    _CompRow('Encrypted vault storage', ['50 MB', '10 GB', '100 GB']),
    _CompRow('Unlimited conversations', [true, true, true]),
    _CompRow('Full-text search', [true, true, true]),
    _CompRow('People & relations', [true, true, true]),
    _CompRow('File import (PDF, audio)', [true, true, true]),
    _CompRow('On-device OCR', [true, true, true]),
    _CompRow('Image capture & gallery', [false, true, true]),
    _CompRow('Cross-device sync', ['Basic', 'Priority', 'Priority']),
    _CompRow('Export (PDF / JSON)', [false, true, true]),
    _CompRow('AI-powered insights', ['Basic', 'Standard', 'Advanced']),
    _CompRow('Custom relation types', [false, false, true]),
    _CompRow('Support', ['Community', 'Email', 'Dedicated']),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final tierColors = [
      const Color(0xFF607D8B),
      const Color(0xFF5C6BC0),
      const Color(0xFF7B1FA2),
    ];

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header row
          Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(11),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text('Feature', style: tt.labelLarge),
                  ),
                ),
                for (int i = 0; i < _tiers.length; i++)
                  Expanded(
                    flex: 2,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: 14,
                        horizontal: 8,
                      ),
                      child: Text(
                        _tiers[i].name,
                        style: tt.labelLarge?.copyWith(color: tierColors[i]),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Data rows
          for (int r = 0; r < _rows.length; r++) ...[
            if (r > 0) Divider(height: 1, color: cs.outlineVariant),
            Container(
              color: r.isOdd ? cs.surfaceContainerLow : null,
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Text(_rows[r].label, style: tt.bodyMedium),
                    ),
                  ),
                  for (int c = 0; c < 3; c++)
                    Expanded(
                      flex: 2,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 8,
                        ),
                        child: _compCell(
                          context,
                          _rows[r].values[c],
                          tierColors[c],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _compCell(BuildContext context, Object value, Color color) {
    if (value is bool) {
      return Icon(
        value ? Icons.check_rounded : Icons.remove_rounded,
        size: 18,
        color: value ? color : Theme.of(context).colorScheme.outlineVariant,
      );
    }
    return Text(
      value.toString(),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w600,
      ),
      textAlign: TextAlign.center,
    );
  }
}

class _CompRow {
  const _CompRow(this.label, this.values);
  final String label;
  final List<Object> values;
}

// ─────────────────────────────────────────────────────────────────────────────
//  FAQ section
// ─────────────────────────────────────────────────────────────────────────────

class _FaqSection extends StatelessWidget {
  const _FaqSection();

  final _items = const [
    _FaqItem(
      question: 'Can I cancel at any time?',
      answer:
          'Yes. Cancelling stops future charges immediately. Your data and vault remain accessible until the end of the paid period.',
    ),
    _FaqItem(
      question: 'Is my data safe?',
      answer:
          'All data is end-to-end encrypted on your device before sync. We have zero knowledge of your vault contents.',
    ),
    _FaqItem(
      question: 'What happens if I exceed my storage?',
      answer:
          'Uploads are blocked once you hit your quota. Your existing data remains intact and accessible. Upgrade to continue syncing.',
    ),
    _FaqItem(
      question: 'Can I switch between plans?',
      answer:
          'Yes. Upgrades take effect immediately. Downgrades apply at the next renewal cycle.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final tt = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Frequently asked questions',
          style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        for (final item in _items) _FaqTile(item: item),
      ],
    );
  }
}

class _FaqItem {
  const _FaqItem({required this.question, required this.answer});
  final String question;
  final String answer;
}

class _FaqTile extends StatelessWidget {
  const _FaqTile({required this.item});
  final _FaqItem item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: ExpansionTile(
        title: Text(
          item.question,
          style: Theme.of(
            context,
          ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              item.answer,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
