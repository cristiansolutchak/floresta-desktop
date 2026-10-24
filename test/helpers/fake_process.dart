import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Scriptable stand-in for a child process. Tests drive output and exit
/// explicitly; signals are recorded and may trigger an exit via [onSignal].
class FakeProcess implements Process {
  FakeProcess({this.pid = 4242, this.onSignal});

  @override
  final int pid;

  /// Called for every `kill`; return an exit code to make the process exit.
  int? Function(ProcessSignal signal)? onSignal;

  final signals = <ProcessSignal>[];
  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _stdin = _NullSink();

  void emitStdout(String line) => _stdout.add(utf8.encode('$line\n'));
  void emitStderr(String line) => _stderr.add(utf8.encode('$line\n'));

  bool get hasExited => _exit.isCompleted;

  Future<void> exit(int code) async {
    if (_exit.isCompleted) return;
    await _stdout.close();
    await _stderr.close();
    _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _stdout.stream;
  @override
  Stream<List<int>> get stderr => _stderr.stream;
  @override
  IOSink get stdin => _stdin;
  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    final code = onSignal?.call(signal);
    if (code != null) unawaited(exit(code));
    return true;
  }
}

class _NullSink implements IOSink {
  @override
  Encoding encoding = utf8;
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain();
  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}

/// Synthetic keys with the right shape for regex-based checks. They are not
/// valid Base58Check and correspond to no real wallet.
abstract final class FakeKeys {
  static const _body =
      '6CbPqb3FCEjaF4LnfMwdEAUxKhC6ZP1sJzGiMMz3mfmcjXdFPM9LB9S8HSChXW593am'
      '685964YZk8Hng1ekynqNWGRZfpo8PpDaUmyvQqvY';
  static const xpub = 'xpub$_body';
  static const tpub = 'tpub$_body';
  static const zpub = 'zpub$_body';
  static const xprv = 'xprv$_body';
  static const tprv = 'tprv$_body';
  static const wifCompressed =
      'L1aW4aubDFB7yfras2S1mN3bqg9nwySY8nkoLmJebSLD5BWv3ENZ';
  static const wifUncompressed =
      '5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ';
}
