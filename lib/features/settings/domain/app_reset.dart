/// INS-12: what each reset removes. Three separate scopes, never combined
/// silently:
///
/// - [ResetScope.settings]: this app's preferences (the first-run wizard
///   runs again). Floresta and its data are untouched.
/// - [ResetScope.managedFloresta]: the florestad copies this app installed
///   in its own folder. A florestad the user chose or built is never touched,
///   and neither is any node data.
/// - [ResetScope.chainData]: the node's data for one network. Only the
///   entries florestad itself creates are removed, never the folder or
///   anything else in it. Needs explicit confirmation naming what is lost.
enum ResetScope { settings, managedFloresta, chainData }

/// Entries florestad v0.9.1 creates in a network's data folder, observed in
/// real runs on regtest and signet (2026-10-25): chain state, Utreexo
/// accumulator blobs, the watch-only wallet database, compact block filters
/// and their index, the node's config cache, known peers and its log.
const florestadDataEntries = <String>[
  'chaindata',
  'blobs',
  'db',
  'cfilters',
  'cfilters-index',
  'conf',
  'peers.json',
  'debug.log',
];

/// A folder is treated as Floresta's only if florestad's chain state is
/// there. Anything else (an empty folder, a Bitcoin Core folder, a home
/// folder) is refused.
bool looksLikeFlorestaData(Set<String> entries) =>
    entries.contains('chaindata') &&
    !entries.contains('chainstate') &&
    !entries.contains('bitcoin.conf');

/// The [florestadDataEntries] actually present, i.e. what a chain-data reset
/// would delete.
List<String> chainDataToDelete(Set<String> entries) => [
  for (final e in florestadDataEntries)
    if (entries.contains(e)) e,
];
