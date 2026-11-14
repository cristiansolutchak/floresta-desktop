import 'dart:convert';

import 'package:equatable/equatable.dart';

/// A port a Docker container publishes on this computer.
class PublishedPort extends Equatable {
  const PublishedPort({
    required this.hostAddress,
    required this.hostPort,
    required this.containerPort,
  });

  /// `0.0.0.0`, `::`, `127.0.0.1`…
  final String hostAddress;
  final int hostPort;
  final int containerPort;

  /// Published on every interface, so other computers on the network can
  /// reach it. florestad's RPC has no password, so this matters.
  bool get onAllInterfaces =>
      hostAddress == '0.0.0.0' || hostAddress == '::' || hostAddress.isEmpty;

  @override
  List<Object?> get props => [hostAddress, hostPort, containerPort];
}

/// One container from `docker ps --all --format '{{json .}}'`.
class DockerContainer extends Equatable {
  const DockerContainer({
    required this.name,
    required this.image,
    required this.command,
    required this.state,
    required this.status,
    required this.ports,
  });

  final String name;
  final String image;
  final String command;

  /// Docker's state word: `running`, `exited`, `paused`…
  final String state;

  /// Docker's human text, e.g. "Up 2 hours".
  final String status;
  final List<PublishedPort> ports;

  bool get running => state == 'running';

  /// Runs Floresta: by image (upstream's `dlsz/floresta`, a local build
  /// named after the project), name or command.
  bool get looksLikeFloresta =>
      [image, name, command].any((s) => s.toLowerCase().contains('floresta'));

  /// The first published port that is [hostPort] on this computer.
  PublishedPort? onHostPort(int hostPort) =>
      ports.where((p) => p.hostPort == hostPort).firstOrNull;

  @override
  List<Object?> get props => [name, image, command, state, status, ports];
}

final _binding = RegExp(r'^\[?([0-9a-fA-F.:]*?)\]?:(\d+)->(\d+)/(tcp|udp)$');

/// Docker's `Ports` text: "0.0.0.0:8332->8332/tcp, :::8332->8332/tcp,
/// 50001/tcp". Unpublished ports ("50001/tcp") are left out.
List<PublishedPort> parseDockerPorts(String text) => [
  for (final part in text.split(','))
    if (_binding.firstMatch(part.trim()) case final m? when m.group(4) == 'tcp')
      PublishedPort(
        hostAddress: m.group(1)!,
        hostPort: int.parse(m.group(2)!),
        containerPort: int.parse(m.group(3)!),
      ),
];

/// One JSON object per line, as `docker ps --format '{{json .}}'` prints.
/// Lines that are not such objects are skipped.
List<DockerContainer> parseDockerPs(String output) {
  final result = <DockerContainer>[];
  for (final line in const LineSplitter().convert(output)) {
    if (line.trim().isEmpty) continue;
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (json is! Map<String, Object?>) continue;
    final map = json;
    String text(String key) => switch (map[key]) {
      final String s => s,
      _ => '',
    };
    result.add(
      DockerContainer(
        name: text('Names'),
        image: text('Image'),
        command: text('Command'),
        state: text('State'),
        status: text('Status'),
        ports: parseDockerPorts(text('Ports')),
      ),
    );
  }
  return result;
}
