import 'package:equatable/equatable.dart';

/// The node's watched descriptors, and whether "none" is certain.
///
/// Right after start, florestad can answer `listdescriptors` with an empty
/// list before it has loaded its stored wallet, so one empty answer does not
/// mean "no wallets"; two in a row do. The UI says "No wallets yet" only when [knownEmpty].
class WatchedList extends Equatable {
  const WatchedList(this.descriptors, {this.emptyAnswers = 0});

  final List<String> descriptors;

  /// Consecutive empty answers so far (0 when the last one was not empty).
  final int emptyAnswers;

  static const emptyAnswersNeeded = 2;

  bool get knownEmpty =>
      descriptors.isEmpty && emptyAnswers >= emptyAnswersNeeded;

  /// Still confirming that the node really watches nothing.
  bool get checking => descriptors.isEmpty && !knownEmpty;

  /// The next state after the node answered [listed].
  WatchedList next(List<String> listed) => listed.isEmpty
      ? WatchedList(const [], emptyAnswers: emptyAnswers + 1)
      : WatchedList(listed);

  @override
  List<Object?> get props => [descriptors, emptyAnswers];
}
