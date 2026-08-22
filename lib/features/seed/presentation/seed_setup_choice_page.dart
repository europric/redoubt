import 'package:flutter/material.dart';

class SeedSetupChoicePage extends StatelessWidget {
  const SeedSetupChoicePage({super.key, this.onGenerate, this.onImport});

  final VoidCallback? onGenerate;
  final VoidCallback? onImport;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Secret Configuration')),
      body: SafeArea(
        child: SingleChildScrollView(
          primary: false,
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _OptionCard(
                key: const Key('generateOption'),
                icon: Icons.edit_outlined,
                title: 'Generate',
                subtitle:
                    'Create a new 24-word recovery phrase using a '
                    'cryptographically secure random generator',
                onTap: onGenerate,
              ),
              const SizedBox(height: 12),
              _OptionCard(
                key: const Key('importOption'),
                icon: Icons.file_download_outlined,
                title: 'Import',
                subtitle:
                    'Import a recovery phrase. Supports an optional BIP-39 '
                    'passphrase (25th word)',
                onTap: onImport,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    final showChevron =
        onTap != null && MediaQuery.textScalerOf(context).scale(1) < 1.3;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: MergeSemantics(
        child: ListTile(
          onTap: onTap,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          minVerticalPadding: 12,
          titleAlignment: ListTileTitleAlignment.top,
          leading: Icon(icon, color: colors.primary),
          title: Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
          trailing: showChevron
              ? Icon(Icons.chevron_right, color: colors.onSurfaceVariant)
              : null,
        ),
      ),
    );
  }
}
