// Release tooling: makes, signs and serves a manifest for artifacts built by
// build_florestad_artifact.sh. Nothing here publishes anything. Production
// manifests are signed with `sign` on the owner's Mac, whose keys live in
// ~/.config/floresta-gui-release/ (owner's decision, 2026-10-27); `assemble`
// remains for a signature made on an offline machine instead.
//
//   dart run tool/release/release_tool.dart keygen   --out <seed file>
//   dart run tool/release/release_tool.dart pubkey   --key <seed file>
//   dart run tool/release/release_tool.dart manifest --artifacts <dir> --serial <n> [--valid-days 90]
//   dart run tool/release/release_tool.dart app-manifest --artifacts <dir> --version <x.y.z> --serial <n> [--notes <text>] [--valid-days 90]
//   dart run tool/release/release_tool.dart sign     --artifacts <dir> --key <seed file> [--key-id dev]
//   dart run tool/release/release_tool.dart assemble --artifacts <dir> --signature <64-byte file> --key-id <id>
//   dart run tool/release/release_tool.dart verify   --artifacts <dir> --public-key <hex> [--key-id dev]
//   dart run tool/release/release_tool.dart serve    --artifacts <dir> [--port 8787]
//
// `manifest` writes <dir>/payload.json (the exact bytes that get signed);
// `sign`/`assemble` write <dir>/manifest.json (the envelope the app reads).
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:blockchain_utils/blockchain_utils.dart';
import 'package:floresta_gui/features/installation/data/signed_manifest.dart';
import 'package:floresta_gui/features/installation/domain/app_update.dart';
import 'package:floresta_gui/features/installation/domain/release_manifest.dart';

Never _die(String message) {
  stderr.writeln('release_tool: $message');
  exit(1);
}

Map<String, String> _flags(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--') || i + 1 >= args.length) {
      _die('bad argument ${args[i]}');
    }
    out[args[i].substring(2)] = args[++i];
  }
  return out;
}

String _need(Map<String, String> f, String name) =>
    f[name] ?? _die('missing --$name');

final _repoRoot = File.fromUri(Platform.script).parent.parent.parent.path;

/// Keys must never live inside the repository, where they could be committed.
void _refuseInsideRepo(String path) {
  final abs = File(path).absolute.path;
  if (abs.startsWith('$_repoRoot${Platform.pathSeparator}')) {
    _die('refusing a key file inside the repository: $abs');
  }
}

List<int> _readSeed(String path) {
  _refuseInsideRepo(path);
  final seed = BytesUtils.fromHexString(File(path).readAsStringSync().trim());
  if (seed.length != 32) _die('a seed file holds 32 bytes as hex');
  return seed;
}

String _publicKeyHex(List<int> seed) => BytesUtils.toHexString(
  Ed25519PrivateKey.fromBytes(seed).publicKey.compressed.sublist(1),
);

void _keygen(Map<String, String> f) {
  final path = _need(f, 'out');
  _refuseInsideRepo(path);
  final file = File(path);
  if (file.existsSync()) _die('$path exists; not overwriting a key');
  final rnd = Random.secure();
  final seed = List<int>.generate(32, (_) => rnd.nextInt(256));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(BytesUtils.toHexString(seed));
  Process.runSync('chmod', ['600', path]);
  stdout.writeln('development key written to $path (mode 600)');
  stdout.writeln('public key: ${_publicKeyHex(seed)}');
  stdout.writeln(
    'build with --dart-define=FLORESTA_DEV_RELEASE_KEY=${_publicKeyHex(seed)}',
  );
}

void _manifest(Map<String, String> f) {
  final dir = Directory(_need(f, 'artifacts'));
  final serial = int.parse(_need(f, 'serial'));
  final validDays = int.parse(f['valid-days'] ?? '90');
  final infos = [
    for (final e in dir.listSync()..sort((a, b) => a.path.compareTo(b.path)))
      if (e is File && e.path.endsWith('.build-info.json'))
        jsonDecode(e.readAsStringSync()) as Map<String, Object?>,
  ];
  if (infos.isEmpty) _die('no *.build-info.json in ${dir.path}');
  final first = infos.first;
  final artifacts = <Map<String, Object?>>[];
  for (final i in infos) {
    for (final k in [
      'version',
      'upstreamTag',
      'upstreamCommit',
      'upstreamRef',
    ]) {
      if (i[k] != first[k]) _die('artifacts disagree on $k');
    }
    final name = i['artifact']! as String;
    final bin = File('${dir.path}/$name');
    final bytes = bin.readAsBytesSync();
    final sha = BytesUtils.toHexString(QuickCrypto.sha256Hash(bytes));
    // Hash what is on disk now, not what the build recorded: OS signing
    // (codesign, Authenticode) changes the bytes after the build.
    if (sha != i['sha256']) {
      stderr.writeln('note: $name changed after build (OS signing?)');
    }
    artifacts.add({
      'os': i['os'],
      'arch': i['arch'],
      'url': name,
      'sha256': sha,
      'size': bytes.length,
      if (i['minOs'] case final String minOs) 'minOs': minOs,
    });
  }
  final now = DateTime.now().toUtc();
  final payload = {
    'type': ReleaseManifest.type,
    'schema': ReleaseManifest.schema,
    'serial': serial,
    'issued': _iso(now),
    'expires': _iso(now.add(Duration(days: validDays))),
    'version': first['version'],
    'upstreamTag': first['upstreamTag'],
    'upstreamCommit': first['upstreamCommit'],
    // `master@<sha>` for a pinned master build, whose --version still says
    // the last version on master; the app shows it next to the version.
    if (first['upstreamRef'] case final String ref) 'upstreamRef': ref,
    'artifacts': artifacts,
  };
  final out = File('${dir.path}/payload.json');
  out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
  stdout.writeln('wrote ${out.path} (${artifacts.length} artifacts)');
}

String _iso(DateTime t) =>
    '${t.toIso8601String().split('.').first.replaceAll(RegExp(r'Z$'), '')}Z';

void _writeEnvelope(Directory dir, String keyId, List<int> signature) {
  final payload = File('${dir.path}/payload.json').readAsBytesSync();
  final envelope = {
    'keyId': keyId,
    'payload': base64.encode(payload),
    'signature': base64.encode(signature),
  };
  final out = File('${dir.path}/manifest.json');
  out.writeAsStringSync(jsonEncode(envelope));
  stdout.writeln('wrote ${out.path} (key $keyId)');
}

void _sign(Map<String, String> f) {
  final dir = Directory(_need(f, 'artifacts'));
  final seed = _readSeed(_need(f, 'key'));
  final payload = File('${dir.path}/payload.json').readAsBytesSync();
  final signature = Ed25519Signer.fromKeyBytes(seed).sign(payload);
  _writeEnvelope(dir, f['key-id'] ?? 'dev', signature);
  _check(dir, f['key-id'] ?? 'dev', _publicKeyHex(seed));
}

/// For signatures made elsewhere, e.g. offline with
/// `openssl pkeyutl -sign -rawin -inkey key.pem -in payload.json -out sig`.
void _assemble(Map<String, String> f) {
  final dir = Directory(_need(f, 'artifacts'));
  final signature = File(_need(f, 'signature')).readAsBytesSync();
  if (signature.length != 64) _die('an Ed25519 signature is 64 bytes');
  _writeEnvelope(dir, _need(f, 'key-id'), signature);
}

void _verify(Map<String, String> f) => _check(
  Directory(_need(f, 'artifacts')),
  f['key-id'] ?? 'dev',
  _need(f, 'public-key'),
);

/// Runs the app's own verifier on the envelope (florestad's or the app's,
/// by the payload's `type`) and re-hashes every artifact.
void _check(Directory dir, String keyId, String publicKeyHex) {
  final bytes = File('${dir.path}/manifest.json').readAsBytesSync();
  final verifier = SignedManifestVerifier([
    TrustedReleaseKey(id: keyId, publicKeyHex: publicKeyHex),
  ]);
  final location = Uri.parse('http://127.0.0.1/manifest.json');
  final payload =
      jsonDecode(
            utf8.decode(
              base64.decode(
                jsonDecode(utf8.decode(bytes))['payload'] as String,
              ),
            ),
          )
          as Map<String, Object?>;
  final List<({Uri url, String sha256, int size})> files;
  final String summary;
  if (payload['type'] == AppReleaseManifest.type) {
    final m = verifier
        .verifyApp(bytes, location)
        .match((f) => _die('verification failed: ${f.message}'), (m) => m);
    files = [
      for (final a in m.artifacts) (url: a.url, sha256: a.sha256, size: a.size),
    ];
    summary =
        'app ${m.version} serial ${m.serial}, ${m.artifacts.length} '
        'packages, expires ${m.expires}';
  } else {
    final m = verifier
        .verify(bytes, location)
        .match((f) => _die('verification failed: ${f.message}'), (m) => m);
    files = [
      for (final a in m.artifacts) (url: a.url, sha256: a.sha256, size: a.size),
    ];
    summary =
        '${m.version} serial ${m.serial}, ${m.artifacts.length} '
        'artifacts, expires ${m.expires}';
  }
  for (final a in files) {
    final file = File('${dir.path}/${a.url.pathSegments.last}');
    final sha = BytesUtils.toHexString(
      QuickCrypto.sha256Hash(file.readAsBytesSync()),
    );
    if (sha != a.sha256 || file.lengthSync() != a.size) {
      _die('${file.path} does not match the manifest');
    }
  }
  stdout.writeln('verified: $summary');
}

/// Writes `<dir>/payload.json` for an app release (ADR-0012) from the
/// packages made by tool/package_macos.sh and tool/package_linux.sh:
/// `Floresta-<v>-macos-<arch>[-unsigned].zip`,
/// `floresta-gui-<v>-linux-<arm64|x64>.tar.gz`,
/// `floresta-gui_<v>_<arm64|amd64>.deb`.
void _appManifest(Map<String, String> f) {
  final dir = Directory(_need(f, 'artifacts'));
  final version = _need(f, 'version');
  final serial = int.parse(_need(f, 'serial'));
  final validDays = int.parse(f['valid-days'] ?? '90');
  final v = RegExp.escape(version);
  final patterns = <(RegExp, String, String Function(Match))>[
    (
      RegExp('^Floresta-$v-macos-(arm64|x64|universal)(-unsigned)?\\.zip\$'),
      'macos-app-zip',
      (m) => m[1]!,
    ),
    (
      RegExp('^floresta-gui-$v-linux-(arm64|x64)\\.tar\\.gz\$'),
      'linux-tar-gz',
      (m) => m[1]!,
    ),
    (
      RegExp('^floresta-gui_${v}_(arm64|amd64)\\.deb\$'),
      'linux-deb',
      (m) => m[1] == 'amd64' ? 'x64' : 'arm64',
    ),
  ];
  final artifacts = <Map<String, Object?>>[];
  for (final e in dir.listSync()..sort((a, b) => a.path.compareTo(b.path))) {
    if (e is! File) continue;
    final name = e.uri.pathSegments.last;
    for (final (re, format, arch) in patterns) {
      final m = re.firstMatch(name);
      if (m == null) continue;
      final os = format.startsWith('macos') ? 'macos' : 'linux';
      if (name.endsWith('-unsigned.zip')) {
        stderr.writeln('note: $name is not signed with a Developer ID');
      }
      final bytes = e.readAsBytesSync();
      artifacts.add({
        'os': os,
        'arch': arch(m),
        'format': format,
        'url': name,
        'sha256': BytesUtils.toHexString(QuickCrypto.sha256Hash(bytes)),
        'size': bytes.length,
        if (os == 'macos') 'minOs': '11.0',
      });
    }
  }
  if (artifacts.isEmpty) _die('no packages for $version in ${dir.path}');
  final now = DateTime.now().toUtc();
  final payload = {
    'type': AppReleaseManifest.type,
    'schema': AppReleaseManifest.schema,
    'serial': serial,
    'issued': _iso(now),
    'expires': _iso(now.add(Duration(days: validDays))),
    'version': version,
    'notes': f['notes'] ?? '',
    'artifacts': artifacts,
  };
  final out = File('${dir.path}/payload.json');
  out.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(payload));
  stdout.writeln('wrote ${out.path} (${artifacts.length} packages)');
}

Future<void> _serve(Map<String, String> f) async {
  final dir = Directory(_need(f, 'artifacts')).absolute;
  final port = int.parse(f['port'] ?? '8787');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln(
    'serving ${dir.path} on http://127.0.0.1:$port/ (Ctrl-C stops)',
  );
  stdout.writeln(
    'build with --dart-define=FLORESTA_RELEASE_MANIFEST_URL='
    'http://127.0.0.1:$port/manifest.json',
  );
  await for (final req in server) {
    final res = req.response;
    final segments = req.uri.pathSegments;
    // Only plain files directly in the directory: no traversal, no listing.
    final name = segments.length == 1 ? segments.single : '';
    final file = File('${dir.path}/$name');
    if (req.method != 'GET' ||
        name.isEmpty ||
        name.startsWith('.') ||
        name.contains('/') ||
        name.contains(r'\') ||
        !file.existsSync()) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      stdout.writeln('404 ${req.method} ${req.uri}');
      continue;
    }
    final length = file.lengthSync();
    var start = 0;
    final range = req.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.startsWith('bytes=')) {
      start = int.tryParse(range.substring(6).split('-').first) ?? 0;
      if (start >= length) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await res.close();
        continue;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${length - 1}/$length',
      );
    }
    res.headers.contentLength = length - start;
    await res.addStream(file.openRead(start));
    await res.close();
    stdout.writeln('${res.statusCode} GET /$name ${range ?? ''}');
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) _die('usage: see the header of this file');
  final f = _flags(args.sublist(1));
  switch (args.first) {
    case 'keygen':
      _keygen(f);
    case 'pubkey':
      // Only the public half, for the app's development configuration.
      stdout.writeln(_publicKeyHex(_readSeed(_need(f, 'key'))));
    case 'manifest':
      _manifest(f);
    case 'app-manifest':
      _appManifest(f);
    case 'sign':
      _sign(f);
    case 'assemble':
      _assemble(f);
    case 'verify':
      _verify(f);
    case 'serve':
      await _serve(f);
    default:
      _die('unknown command ${args.first}');
  }
}
