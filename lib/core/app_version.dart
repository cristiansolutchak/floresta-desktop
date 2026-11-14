/// This app's version, as in `pubspec.yaml` (`version`, without the build
/// number). Kept in code so no package is needed to read it at runtime;
/// `test/core/app_version_test.dart` fails if the two drift apart. The
/// release tooling compares it with the update manifest.
const appVersionText = '0.0.1-beta';
