import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// This app's licence, florestad's (the app installs it) and the bundled
/// font's, listed with the packages' licences (Help > Licences).
void registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Floresta GUI',
    ], await rootBundle.loadString('LICENSE-MIT'));
    yield LicenseEntryWithLineBreaks(const [
      'Floresta GUI',
    ], await rootBundle.loadString('LICENSE-APACHE'));
    yield LicenseEntryWithLineBreaks(const [
      'florestad (Floresta)',
    ], await rootBundle.loadString('assets/licenses/floresta-LICENSE-MIT'));
    yield LicenseEntryWithLineBreaks(const [
      'Space Grotesk',
    ], await rootBundle.loadString('assets/fonts/Space_Grotesk/OFL.txt'));
  });
}
