import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/installation/presentation/installation_page.dart';
import '../../features/console/domain/console_template.dart';
import '../../features/console/presentation/console_page.dart';
import '../../features/help/presentation/help_page.dart';
import '../../features/node/presentation/logs_page.dart';
import '../../features/node/presentation/overview_page.dart';
import '../../features/node/presentation/peers_page.dart';
import '../../features/node/presentation/sync_page.dart';
import '../../features/onboarding/presentation/onboarding_pages.dart';
import '../../features/settings/presentation/settings_controller.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/wallet/presentation/wallet_page.dart';
import '../shell/app_shell.dart';

/// A short fade between screens: quick enough to feel instant, like a
/// native sidebar app, without the hard cut. None with reduced motion.
Page<void> _page(GoRouterState state, Widget child) => CustomTransitionPage(
  key: state.pageKey,
  child: child,
  transitionDuration: const Duration(milliseconds: 150),
  reverseTransitionDuration: const Duration(milliseconds: 150),
  transitionsBuilder: (context, animation, _, child) =>
      MediaQuery.disableAnimationsOf(context)
      ? child
      : FadeTransition(
          opacity: CurveTween(curve: Curves.easeOut).animate(animation),
          child: child,
        ),
);

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
            pageBuilder: (_, s) => _page(s, const OverviewPage()),
          ),
          GoRoute(
            path: '/sync',
            pageBuilder: (_, s) => _page(s, const SyncPage()),
          ),
          GoRoute(
            path: '/peers',
            pageBuilder: (_, s) => _page(s, const PeersPage()),
          ),
          GoRoute(
            path: '/rpc',
            pageBuilder: (_, s) => _page(
              s,
              const ConsolePage(ConsoleKind.rpc, key: ValueKey('rpc')),
            ),
          ),
          GoRoute(
            path: '/electrum',
            pageBuilder: (_, s) => _page(
              s,
              const ConsolePage(
                ConsoleKind.electrum,
                key: ValueKey('electrum'),
              ),
            ),
          ),
          GoRoute(
            path: '/logs',
            pageBuilder: (_, s) => _page(s, const LogsPage()),
          ),
          GoRoute(
            path: '/help',
            pageBuilder: (_, s) => _page(s, const HelpPage()),
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
