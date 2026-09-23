/// Recovers the `<role> start …` command from a service's recorded arguments.
///
/// A service installed while omnyshell ran under the Dart VM records its
/// arguments as `[<script>, <role>, start, …]`: the launching snapshot is
/// baked in ahead of the command. Feeding that vector back into
/// `ServiceDescriptor.forCurrentExecutable` on a reinstall keeps the stale
/// script — an AOT binary then runs `omnyshell <old snapshot> hub start …`, and
/// a VM whose snapshot path changed (an SDK upgrade) runs
/// `dart <new snapshot> <old snapshot> hub start …`.
///
/// Returns [stored] from the first `<role> start` pair onward, dropping any
/// runtime prefix so the descriptor re-derives exactly one for the current
/// executable. When no such pair is found, [stored] is returned unchanged.
List<String> serviceCommandArgs(String role, List<String> stored) {
  for (var i = 0; i + 1 < stored.length; i++) {
    if (stored[i] == role && stored[i + 1] == 'start') {
      return stored.sublist(i);
    }
  }
  return List.of(stored);
}
