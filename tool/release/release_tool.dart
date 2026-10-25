// Development release tooling: makes, signs and serves a manifest for
// artifacts built by build_florestad_artifact.sh. Nothing here publishes
// anything, and production keys never pass through this tool: a production
// signature is made offline (see `assemble`).
//
//   dart run tool/release/release_tool.dart keygen   --out <seed file>
//   dart run tool/release/release_tool.dart manifest --artifacts <dir> --serial <n> [--valid-days 90]
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
    for (final k in ['version', 'upstreamTag', 'upstreamCommit']) {
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

/// Runs the app's own verifier on the envelope and re-hashes every artifact.
void _check(Directory dir, String keyId, String publicKeyHex) {
  final bytes = File('${dir.path}/manifest.json').readAsBytesSync();
  final verifier = SignedManifestVerifier([
    TrustedReleaseKey(id: keyId, publicKeyHex: publicKeyHex),
  ]);
  final manifest = verifier
      .verify(bytes, Uri.parse('http://127.0.0.1/manifest.json'))
      .match((f) => _die('verification failed: ${f.message}'), (m) => m);
  for (final a in manifest.artifacts) {
    final file = File('${dir.path}/${a.url.pathSegments.last}');
    final sha = BytesUtils.toHexString(
      QuickCrypto.sha256Hash(file.readAsBytesSync()),
    );
    if (sha != a.sha256 || file.lengthSync() != a.size) {
      _die('${file.path} does not match the manifest');
    }
  }
  stdout.writeln(
    'verified: ${manifest.version} serial ${manifest.serial}, '
    '${manifest.artifacts.length} artifacts, expires ${manifest.expires}',
  );
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
    case 'manifest':
      _manifest(f);
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
