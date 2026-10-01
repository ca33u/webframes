import Foundation

/// Runs a child command under a tiny `/bin/sh` supervisor that
/// (a) stops the whole process tree when asked, not just the top command
///     (`npm run dev` → `next dev`), and
/// (b) stops that tree if Web Frames disappears without asking — a crash
///     or force-quit used to leave dev servers holding their port.
///
/// `Process.interrupt()` / `terminate()` reach the supervisor, which sends
/// SIGTERM to every process in the tree (TERM rather than INT because a
/// background job of a non-interactive shell has SIGINT ignored). The
/// supervisor exits when the command exits, so `terminationHandler`
/// semantics are unchanged. Verified against bash in POSIX mode.
nonisolated enum ChildProcessWatchdog {
    static let script = """
    parent=$PPID
    "$@" &
    child=$!
    tree() { echo "$1"; for c in $(pgrep -P "$1" 2>/dev/null); do tree "$c"; done; }
    stop() { for p in $(tree "$child"); do kill -"$1" "$p" 2>/dev/null; done; }
    trap 'stop TERM' INT TERM
    while kill -0 "$child" 2>/dev/null; do
      if ! kill -0 "$parent" 2>/dev/null; then
        stop TERM; sleep 2; stop KILL
        break
      fi
      sleep 1
    done
    wait "$child"
    """

    static func wrap(executable: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        (URL(fileURLWithPath: "/bin/sh"), ["-c", script, "webframes-watchdog", executable.path] + arguments)
    }
}
