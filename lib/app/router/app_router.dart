import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/installation/presentation/installation_page.dart';
import '../../features/node/presentation/node_overview_page.dart';
import '../../features/onboarding/presentation/onboarding_pages.dart';
import '../../features/settings/presentation/settings_controller.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/wallet/presentation/wallet_page.dart';
import '../shell/app_shell.dart';

/// No transition animations: this is a desktop app, and sections switch
/// instantly like native sidebar apps.
Page<void> _page(GoRouterState state, Widget child) =>
    NoTransitionPage(key: state.pageKey, child: child);

final appRouterProvider = Provider<GoRouter>((ref) {
  final router = GoRouter(
    initialLocation: '/node',
    // Reads settings at navigation time, so completing onboarding takes
    // effect on the next `go` without rebuilding the router.
    redirect: (context, state) {
      final onboarded = ref.read(settingsControllerProvider).onboardingComplete;
      final inOnboarding =
          state.matchedLocation == '/welcome' ||
          state.matchedLocation.startsWith('/onboarding');
      if (!onboarded && !inOnboarding) return '/welcome';
      if (onboarded && state.matchedLocation == '/welcome') return '/node';
      return null;
    },
    routes: [
      GoRoute(
        path: '/welcome',
        pageBuilder: (_, s) => _page(s, const WelcomePage()),
      ),
      GoRoute(
        path: '/onboarding/install',
        pageBuilder: (_, s) => _page(s, const InstallStepPage()),
      ),
      GoRoute(
        path: '/onboarding/setup',
        pageBuilder: (_, s) => _page(s, const SetupStepPage()),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/node',
            pageBuilder: (_, s) => _page(s, const NodeOverviewPage()),
          ),
          GoRoute(
            path: '/wallet',
            pageBuilder: (_, s) => _page(s, const WalletPage()),
          ),
          GoRoute(
            path: '/installation',
            pageBuilder: (_, s) => _page(s, const InstallationPage()),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (_, s) => _page(s, const SettingsPage()),
          ),
        ],
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});
