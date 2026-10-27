import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/node/presentation/node_controller.dart';
import 'brand/startup_splash.dart';
import 'router/app_router.dart';
import 'theme/app_theme.dart';

class FlorestaApp extends ConsumerStatefulWidget {
  const FlorestaApp({super.key});

  @override
  ConsumerState<FlorestaApp> createState() => _FlorestaAppState();
}

class _FlorestaAppState extends ConsumerState<FlorestaApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  /// Stops a node this app started before quitting, so florestad is not
  /// left running orphaned and its state is flushed cleanly.
  Future<AppExitResponse> _onExitRequested() async {
    final manager = ref.read(nodeProcessManagerProvider);
    if (manager.state.isActive) await manager.stop();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Floresta',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(appRouterProvider),
      builder: (context, child) =>
          StartupSplash(child: child ?? const SizedBox.shrink()),
    );
  }
}
