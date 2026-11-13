# Rules for anyone (or any AI agent) changing Indra

Indra is built by many short patches, and problems that were fixed came back more than once because a later patch did not
know why the earlier code looked the way it did. Read this before changing anything, and run `scripts/guard.sh` before
sending a patch. If a check fails, the change brings back an old problem.

## Things that must stay true

1. **Dropped files are read in one place** (`Tray/DropFiles.swift`). Never call `readObjects(forClasses: [NSURL.self])`
   or ask a promise for its file URL anywhere else: the sender then writes or moves the file to the Desktop.
2. **Every AppleScript goes through `AppleScriptGate`** (one at a time, 5 s limit). A script without a limit once stopped
   now-playing, the queue and the lyrics at the same time.
3. **No waiting on the main thread.** No `Thread.sleep`, `waitUntilExit`, semaphores or `DispatchQueue.main.sync` on the
   main actor. Anything that talks to another process (`Process`, `proc_pidinfo`, window lists of other apps, permission
   prompts) runs in a background task.
4. **Everything that is registered must be removable.** `NSEvent` monitors, `NotificationCenter` observers, timers and
   private window-server Spaces are stored in a property and removed in a `shutdown()`. A controller that can be created
   more than once (the external monitor's island) must be shut down before the reference is dropped.
5. **Caches have a limit.** Anything keyed by a song, a colour, a size or a time needs an upper bound and an eviction. Anything that holds
   pictures or files is limited by bytes, not only by count. Use `SharedCI.context` instead of making a new `CIContext`.
6. **No crashes by design.** No `try!`, no `as!`, no `fatalError` except `init(coder:)`, no array index without a check on
   data that comes from outside (AppleScript output, JSON, the web).
7. **Window-server calls are rare.** `CGWindowListCopyWindowInfo`, `CGSessionCopyCurrentDictionary` and similar are round
   trips to the window server. Ask once per check, never once per item, and use the cached variants in loops.
8. **Fix the cause, then leave a trace.** When a bug is fixed, add a line to `scripts/guard.sh` (or a unit test) that fails
   if the same mistake comes back, and a `Trace.log` line that shows which path ran.

## Patch format
One cumulative patch per release, a full diff from the first commit, `VERSION` and `project.yml`
(`CURRENT_PROJECT_VERSION`) bumped together. Test-apply it to a copy of the starter commit before sending.
