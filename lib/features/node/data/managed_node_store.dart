import 'dart:convert';
import 'dart:io';

import '../../../core/platform/app_paths.dart';
import '../domain/managed_node_record.dart';

/// Persists [ManagedNodeRecord] in `node.json`, replaced atomically.
class ManagedNodeStore {
  ManagedNodeStore(this.paths);

  final AppPaths paths;

  /// Null when absent or unreadable (an unreadable record only means the
  /// app cannot adopt a leftover node; it is then treated as external).
  Future<ManagedNodeRecord?> read() async {
    final file = paths.nodeRecord;
    if (!await file.exists()) return null;
    try {
      return ManagedNodeRecord.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, Object?>,
      );
    } on Object {
      return null;
    }
  }

  Future<void> write(ManagedNodeRecord record) async {
    final file = paths.nodeRecord;
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(record.toJson()), flush: true);
    await temp.rename(file.path);
  }

  /// Idempotent: a record already removed (or never written) is fine.
  Future<void> clear() async {
    try {
      await paths.nodeRecord.delete();
    } on PathNotFoundException {
      // Nothing to forget.
    }
  }
}
