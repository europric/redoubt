import 'package:flutter/widgets.dart';

/// Creates and owns a `ChangeNotifier`-based controller for a widget
/// subtree (design.md's "`ControllerHost<C>` CREATES the controller" —
/// REV 2, superseding an earlier "adopts an already-constructed controller"
/// design that could not fix a leak whose root cause was construction
/// happening BEFORE the host ever saw the instance).
///
/// [create] is invoked EXACTLY ONCE, in `initState`. `late final
/// _controller` makes a second assignment throw rather than silently leak
/// — the "exactly one controller per mounted host" invariant is
/// language-enforced. A rebuild that supplies a brand-new [create] closure
/// is deliberately ignored: [create] is never read outside `initState`.
///
/// [onAttach] receives `(BuildContext, C)` so one-shot wiring (e.g.
/// starting an async operation, or registering a completion callback) runs
/// exactly once at mount, while still being able to guard any deferred
/// callback with `context.mounted`. Wiring one-shot callbacks inside
/// [builder] instead would re-register them on every rebuild.
///
/// [builder] rebuilds whenever the controller calls `notifyListeners()`,
/// via an inner `ListenableBuilder`.
///
/// On unmount, the created controller's `dispose()` is called exactly once.
class ControllerHost<C extends ChangeNotifier> extends StatefulWidget {
  const ControllerHost({
    super.key,
    required this.create,
    required this.builder,
    this.onAttach,
  });

  /// Invoked exactly once, in `initState`, to construct the controller this
  /// host owns for its whole mounted lifetime.
  final C Function() create;

  /// Invoked exactly once, right after [create], with the host's
  /// `BuildContext` and the newly created controller. Use this for one-shot
  /// wiring (e.g. starting an async operation).
  final void Function(BuildContext context, C controller)? onAttach;

  /// Rebuilt whenever the controller notifies its listeners.
  final Widget Function(BuildContext context, C controller) builder;

  @override
  State<ControllerHost<C>> createState() => _ControllerHostState<C>();
}

class _ControllerHostState<C extends ChangeNotifier>
    extends State<ControllerHost<C>> {
  late final C _controller;

  @override
  void initState() {
    super.initState();
    _controller = widget.create();
    widget.onAttach?.call(context, _controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => widget.builder(context, _controller),
  );
}
