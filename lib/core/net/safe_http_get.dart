import 'dart:async';
import 'dart:io';

/// HTTPS GETs with checked redirects, shared by the Floresta installer and
/// the Swift Sync hints download.

bool isLoopbackUrl(Uri url) =>
    url.host == '127.0.0.1' || url.host == 'localhost' || url.host == '::1';

/// Only HTTPS, except plain HTTP to the loopback interface (local artifact
/// servers in tests and development).
bool isAllowedDownloadUrl(Uri url) =>
    url.scheme == 'https' || (url.scheme == 'http' && isLoopbackUrl(url));

/// Whether a redirect from [from] to [to] may be followed: never to a
/// weaker scheme, and only to the same host or an allowlisted HTTPS host.
bool isAllowedRedirect(Uri from, Uri to, Set<String> allowedHosts) {
  if (!isAllowedDownloadUrl(to)) return false;
  if (from.scheme == 'https' && to.scheme != 'https') return false;
  if (to.host == from.host) return true;
  return to.scheme == 'https' && allowedHosts.contains(to.host.toLowerCase());
}

class RedirectRefused implements Exception {
  const RedirectRefused(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

const maxRedirects = 3;

/// GETs [url], following at most [maxRedirects] redirects by hand so each
/// hop is checked with [isAllowedRedirect]. [prepare] runs on every hop's
/// request (e.g. to resend a Range header). Throws [RedirectRefused].
Future<HttpClientResponse> openFollowingRedirects(
  HttpClient client,
  Uri url, {
  required Duration timeout,
  Set<String> allowedHosts = const {},
  void Function(HttpClientRequest request)? prepare,
}) async {
  var current = url;
  for (var hop = 0; ; hop++) {
    final request = await client.getUrl(current);
    request.followRedirects = false;
    prepare?.call(request);
    final response = await request.close().timeout(timeout);
    if (!response.isRedirect) return response;
    final location = response.headers.value(HttpHeaders.locationHeader);
    await response.drain<void>();
    if (location == null) {
      throw const RedirectRefused('redirect without a location');
    }
    final next = current.resolve(location);
    if (hop >= maxRedirects) throw const RedirectRefused('too many redirects');
    if (!isAllowedRedirect(current, next, allowedHosts)) {
      throw RedirectRefused(
        'refused redirect to ${next.scheme}://${next.host}',
      );
    }
    current = next;
  }
}
