import 'package:floresta_desktop/features/node/domain/node_process_state.dart';
import 'package:floresta_desktop/features/node/domain/node_readiness.dart';
import 'package:floresta_desktop/features/node/domain/node_status.dart';
import 'package:floresta_desktop/features/node/presentation/node_status_banner.dart';
import 'package:floresta_desktop/features/node/presentation/status_labels.dart';
import 'package:floresta_desktop/shared/widgets/common.dart';
import 'package:flutter_test/flutter_test.dart';

String _message(
  String label, {
  NodeStatus status = const NodeStatus(process: ProcessIdle()),
  bool existing = false,
}) => bannerMessage(
  short: (label: label, caption: null, tone: Tone.neutral),
  readiness: const NodeReadiness(ReadinessStage.stopped),
  status: status,
  useExistingNode: existing,
  rpcPort: 8332,
);

void main() {
  group('bannerMessage (Overview and Sync share it)', () {
    test('"leave it running in the background" only while syncing', () {
      const background = 'leave it running in the background';
      expect(_message('Syncing'), contains(background));
      for (final other in [
        'Synced',
        'Stopped',
        'Starting',
        'Stopping',
        'Error',
        'Stalled',
      ]) {
        expect(_message(other), isNot(contains(background)), reason: other);
      }
    });

    test('a stopped node elsewhere is not asked to start here', () {
      expect(_message('Stopped'), contains('Start it'));
      final elsewhere = _message('Stopped', existing: true);
      expect(elsewhere, contains('127.0.0.1:8332'));
      expect(elsewhere, contains('where it runs'));
    });

    test('an error carries the exit detail once', () {
      final m = _message(
        'Error',
        status: const NodeStatus(process: ProcessCrashed(101, [])),
      );
      expect(m, contains('Exit code 101'));
      expect(m, contains('Check the logs'));
    });

    test('labels and captions are the ones StatusLabels gives', () {
      const status = NodeStatus(process: ProcessIdle());
      expect(
        StatusLabels.short(
          const NodeReadiness(ReadinessStage.stopped),
          status,
        ).label,
        'Stopped',
      );
    });
  });
}
