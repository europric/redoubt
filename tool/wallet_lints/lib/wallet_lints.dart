import 'package:custom_lint_builder/custom_lint_builder.dart';

/// No-op stand-in for the private wallet_lints plugin — see pubspec.yaml.
PluginBase createPlugin() => _NoOpPlugin();

class _NoOpPlugin extends PluginBase {
  @override
  List<LintRule> getLintRules(CustomLintConfigs configs) => [];
}
