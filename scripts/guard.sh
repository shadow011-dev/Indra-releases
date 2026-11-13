#!/bin/bash
# v504: regression guard. Each check below protects a fix that was made (and later undone by accident) more than once.
# Run it before sending or applying a patch:  scripts/guard.sh   (exit status 1 = something that was fixed came back)
# It reads the source only; nothing is built or changed.
cd "$(dirname "$0")/.."
SRC=Indra
fail=0
bad() { echo "GUARD FAIL: $1"; shift; for line in "$@"; do echo "    $line"; done; fail=1; }

# 1. Dropped files are read only by Tray/DropFiles.swift. Reading them anywhere else (readObjects with NSURL) asks the
#    sender for the file, and the sender then leaves a copy (or moves the file) on the Desktop. (v485, v490, v498, v500)
hits=$(grep -rn 'readObjects(forClasses: \[NSURL.self\]' $SRC --include=*.swift | grep -v 'Tray/DropFiles.swift')
[ -n "$hits" ] && bad "files of a drag read outside Tray/DropFiles.swift" "$hits"

# 2. Every AppleScript goes through AppleScriptGate (one at a time, with a time limit). Two scripts at once, or one without
#    a limit, stopped now-playing, the queue and the lyrics together. (v419, v491)
for f in $(grep -rl 'NSAppleScript(' $SRC --include=*.swift); do
  grep -q 'AppleScriptGate' "$f" || bad "$f runs an AppleScript without AppleScriptGate"
done

# 3. Nothing may block a thread on the main actor. These files are the reviewed places that wait (they all run off the main
#    thread, or on a thread of their own). A new file with a wait must be reviewed and added here on purpose.
allowed='KeystrokeInjector|SecureCredentialManager|MirrorController|SystemKeyInterceptor|Diagnostics|HealthMonitor|TrackpadActuator|YouTubeProbe|NowPlayingHelper'
hits=$(grep -rnE 'Thread\.sleep|waitUntilExit|DispatchSemaphore|DispatchQueue\.main\.sync|usleep\(' $SRC --include=*.swift | grep -vE "($allowed)\.swift")
[ -n "$hits" ] && bad "a wait that can block the main thread, in a file nobody reviewed for it" "$hits"

# 4. No crashes by design: no try!, no forced casts, no fatalError except the required init(coder:).
hits=$(grep -rnE 'try!|[^a-zA-Z]as!' $SRC --include=*.swift | grep -vE '^\S+:[0-9]+:\s*//')
[ -n "$hits" ] && bad "try! or a forced cast" "$hits"
hits=$(grep -rn 'fatalError(' $SRC --include=*.swift | grep -v 'init(coder:)')
[ -n "$hits" ] && bad "fatalError outside init(coder:)" "$hits"

# 5. An island (the second notch on an external monitor) must be shut down before it is dropped. Dropping the reference
#    only left its monitors, observers, timer and private Space behind for good, once per plug / unplug. (v504)
grep -n 'island = nil' $SRC/Notch/NotchWindowController.swift | while IFS=: read -r line rest; do
  prev=$(sed -n "$((line-1))p" $SRC/Notch/NotchWindowController.swift)
  echo "$prev" | grep -q 'shutdown()' || { echo "GUARD FAIL: 'island = nil' (line $line) without existing.shutdown() right before it"; exit 1; }
done || fail=1

# 6. Every window-server Space that is created must be destroyed again (StickySpace.destroy). (v504)
grep -q 'func destroy()' $SRC/Notch/StickySpace.swift || bad "StickySpace.destroy() is gone"

# 7. The version in VERSION and project.yml agree.
v=$(tr -d '[:space:]' < VERSION)
grep -q "CURRENT_PROJECT_VERSION: \"$v\"" project.yml || bad "VERSION ($v) and project.yml CURRENT_PROJECT_VERSION differ"

# 8. App Lock: one look at the window list per check, never one per app. (v504)
n=$(grep -c 'CGWindowListCopyWindowInfo' $SRC/FaceLock/AppLock/AppLockController.swift)
[ "$n" -le 1 ] || bad "AppLockController asks for the window list more than once per check ($n places)"

# 9. One shared Core Image context (SharedCI.context). Every extra CIContext keeps its own GPU buffers for as long as it lives. (v506)
hits=$(grep -rn 'CIContext(' $SRC --include=*.swift | grep -vE 'App/SharedCI.swift|Lock/AlbumPhotoBackdrop.swift')
[ -n "$hits" ] && bad "a new CIContext (use SharedCI.context)" "$hits"

# 10. Pictures kept in memory by the clipboard are limited by size as well as by count. (v506)
grep -q 'imageBudgetBytes' $SRC/Zen/ClipboardStore.swift || bad "the clipboard picture budget is gone"

# 11. The space bar on the lock screen is not tied to "On space" alone: App Lock's "Scan only on notch hover or button" also lets
#     it start the scan there, and a notch parked for App Lock is handed back before the lock screen arms it. (v507)
grep -q 'spaceStartsScan' $SRC/FaceLock/FaceUnlockCoordinator.swift || bad "the lock-screen space bar rule (spaceStartsScan) is gone"
grep -q 'releaseHoverScan()' $SRC/FaceLock/FaceUnlockCoordinator.swift || bad "the lock screen no longer takes the notch over from App Lock's hover park"

# 12. The closed notch's circle visualizer redraws at 30 frames a second at most (60 doubled the idle CPU). (v507)
grep -q 'return TimelineView(.animation(minimumInterval: 1.0 / 60.0' $SRC/Media/Visualizers.swift && bad "the circle visualizer is back to 60 frames a second"

# 13. The lock-screen space bar reader keeps its counters PER MONITOR (a shared static was zeroed every second by the App Lock
#     cover's monitor) and has the "first key" fallback for a lock screen that hides the keyboard from both readers. (v508)
grep -qE 'static var (hidEvents|seenKeyLogs)' $SRC/FaceLock/SpaceKeyMonitor.swift && bad "SpaceKeyMonitor counters are shared statics again"
grep -q 'allowsAnyKeyFallback' $SRC/FaceLock/SpaceKeyMonitor.swift || bad "the lock screen 'first key' fallback is gone"
grep -q 'allowsAnyKeyFallback = true' $SRC/FaceLock/FaceUnlockCoordinator.swift || bad "the lock screen monitor no longer turns the 'first key' fallback on"

# 14. An observer or timer whose closure only hands over to a Task with [weak self] must itself capture self weakly: the outer
#     closure otherwise holds self for as long as the observer or timer lives (the compiler's "ImplicitStrongCapture" warning). (v522)
hits=$(perl scripts/weakself_check.pl $(grep -rl 'MainActor \[weak self\]' $SRC --include=*.swift))
[ -z "$hits" ] || bad "an observer or timer closure holds self strongly (add [weak self] to the outer closure)" $hits
# 15. The lyrics store keeps its settings observer's token so it can remove it. (v522)
grep -q 'defaultsObserver' $SRC/Lock/LyricsStore.swift || bad "LyricsStore no longer keeps its UserDefaults observer token"

# 16. LiveActivityMonitor registers a run-loop source with an unretained pointer to itself, so it must have a stop() that removes it,
#     and the notch controller calls it when it shuts down. (v523)
grep -q 'func stop()' $SRC/Live/LiveActivity.swift || bad "LiveActivityMonitor.stop() is gone"
grep -q 'liveMonitor?.stop()' $SRC/Notch/NotchWindowController.swift || bad "NotchWindowController.shutdown() no longer stops the live monitor"

# 17. The cover caches are limited by bytes as well as by count (80 covers of 900 px were up to 260 MB). (v523)
grep -q 'byteLimit' $SRC/Media/MediaModels.swift || bad "BoundedImageCache lost its byte budget"

# 18. The lock window sits invisible all day: its per-frame and per-second timelines must pause while it is not shown. (v523)
grep -q 'paused: (!isPlaying && !sliderRevealing) || !sliderVisible || !model.shown' $SRC/Lock/LockScreenView.swift || bad "the lock screen progress bar redraws every frame while the lock window is hidden again"
grep -q 'TimelineView(.animation(minimumInterval: 1, paused: !model.shown))' $SRC/Lock/LockScreenView.swift || bad "the lock screen clock redraws every second while the lock window is hidden again"

# 19. ClockStyles' glyph cache has one eviction line, at 40 (a second one at 24 made the 40 dead code). (v523)
[ "$(grep -c 'cache.removeAll()' $SRC/Lock/ClockStyles.swift)" -eq 1 ] || bad "ClockStyles has more than one eviction line for the same cache"

# 20. No spindle hole on the lock screen vinyl or on the side records. (v523)
grep -q 'size \* 0.045' $SRC/Lock/VinylPod.swift && bad "the lock screen vinyl has its centre hole back"
grep -q 'width: 3.5, height: 3.5' $SRC/Lock/QueueDock.swift && bad "the side records have their centre dot back"

# 21. The lock / unlock sounds are two fixed iPhone-style sounds made in memory, with no picker (the system-sound choices are gone). (v524)
grep -rqE 'lockSoundChoices|lockSoundNameKey|unlockSoundNameKey' $SRC --include=*.swift && bad "the lock / unlock sound pickers are back"
grep -q 'makeClick' $SRC/Lock/LockSounds.swift || bad "LockSounds no longer makes its own iPhone-style sounds"

# 22. App Lock: the space bar and a notch hover start a face scan whether "Scan only on notch hover or button" is on or off
#     (off: once the first scan has ended). The space reader must not be tied to the setting. (v525)
grep -q 'guard scansOnDemand, isTargetActive, isCoverShown' $SRC/FaceLock/AppLock/AppLockOverlay.swift && bad "the App Lock space bar only works with 'scan only on hover' on again"
grep -q 'hoverRearmWanted' $SRC/FaceLock/AppLock/AppLockOverlay.swift || bad "App Lock no longer re-parks the notch for a hover when 'scan only on hover' is off"

# 23. The lock screen volume / brightness overlay: a locked screen is not idle (reads go on), and a lock never switches the idle flag. (v525)
grep -q 'case "com.apple.screenIsLocked": self?.screenLocked = true' $SRC/Sensory/SensoryMonitor.swift || bad "SensoryMonitor treats a locked screen as idle again (no brightness overlay on the lock screen)"

# 24. A space press on the lock screen never cuts into the notch's collapse. (v525)
grep -q 'spaceAfterCollapseTask' $SRC/FaceLock/FaceUnlockCoordinator.swift || bad "the lock screen space press no longer waits out the notch's collapse"

# 25. The lock screen volume / brightness overlay is also started by the key press itself (the key tap is off while locked,
#     and a press at full / zero volume changes nothing for the change listener to see). (v526)
grep -q 'lockScreenKeyPressed' $SRC/Sensory/SensoryMonitor.swift || bad "the lock screen overlay no longer reacts to the volume / brightness key press itself"

# 26. The volume / brightness key tap stays on while the screen is only locked (so macOS's own pop-up never shows next to
#     Indra's on the lock screen); only display / Mac sleep switch it off. (v527)
grep -q 'Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in off() }' $SRC/Sensory/SystemKeyInterceptor.swift && bad "the key tap is switched off on lock again: macOS's volume / brightness pop-up shows on the lock screen"

# 27. Lock screen: macOS's own volume / brightness pop-up must never show next to Indra's. The key tap is checked when the screen locks
#     (ensureTapAlive), is not switched off by the session-resign notification that arrives while locking, waits longer for the main
#     thread while locked, and a key that still reaches macOS there makes SystemHUDSuppressor keep macOS's helper from drawing. (v528)
grep -q 'ensureTapAlive' $SRC/Sensory/SystemKeyInterceptor.swift || bad "the key tap is no longer checked when the screen locks"
grep -q 'if !LockMonitorSnapshot.isLockedOrAsleep { off() }' $SRC/Sensory/SystemKeyInterceptor.swift && bad "the session-resign notification switches the key tap off while the screen is locking again"
grep -q 'timeout: locked ? 0.15 : 0.04' $SRC/Sensory/SystemKeyInterceptor.swift || bad "the key tap no longer waits longer for the main thread on the lock screen"
grep -q 'SystemHUDSuppressor.suppress' $SRC/Sensory/SensoryMonitor.swift || bad "a lock screen key that reaches macOS no longer keeps macOS's pop-up from drawing"

# 28. The app icon and the menu bar icon are the ones the user chose (v529): the default menu bar icon is the MenuBarIcon asset, and the
#     status item is as wide as that icon (a square item would shrink it to a sliver).
[ -f $SRC/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.png ] || bad "the MenuBarIcon asset is gone"
grep -q 'case "": return bundledIcon' $SRC/FaceLock/MenuBarIconTinter.swift || bad "the default menu bar icon is no longer the bundled MenuBarIcon"
grep -q 'NSStatusItem.squareLength' $SRC/FaceLock/FaceLockMenuBar.swift && bad "the menu bar item is square again, which shrinks the wide icon"

# 29. The intro animation (v530) is the bundled video in the open notch's shape. The video must be in the app, its view must give the
#     player and its observer back when it leaves, the preview observer must be kept so it can be removed, and the old downline
#     "Indra" greeting must not come back.
[ -f $SRC/Resources/IndraIntro.mp4 ] || bad "the intro video (Resources/IndraIntro.mp4) is gone"
[ -f $SRC/Resources/IndraThunder.mp3 ] || bad "the intro's thunder (Resources/IndraThunder.mp3) is gone"
grep -q 'removeTimeObserver(boundaryObserver)' $SRC/Live/IntroAnimation.swift || bad "the intro video's thunder / early-end time observer is not removed when the view leaves the screen"
grep -q 'dismantleNSView' $SRC/Live/IntroAnimation.swift || bad "IntroVideoView no longer gives its player back when it leaves the screen"
grep -q 'looseObservers.append(NotificationCenter.default.addObserver(forName: .indraWelcomePreview' $SRC/Notch/NotchWindowController.swift || bad "the intro preview observer is not kept for removal"
grep -rq 'WelcomeDownlineView' $SRC --include=*.swift && bad "the old downline welcome greeting is back"

# v534. A stray copy of an app / folder / package on the Desktop is cleaned up too (not only plain files), after a 2 s wait.
grep -q 'case folder' $SRC/Tray/DesktopCopyGuard.swift || bad "DesktopCopyGuard no longer handles apps, packages and folders"
grep -q 'settle: TimeInterval = 2' $SRC/Tray/DesktopCopyGuard.swift || bad "DesktopCopyGuard no longer waits 2 s before touching the stray file (Blip showed 'no file found')"

# v537. The Battery page has no "Preview the animation" row, and the 3D device renders can always be switched back on from Settings > Bluetooth
#       (the crash guard switches them off, and for a while nothing could undo that, so the old flat animations stayed).
grep -rq 'indraBatteryPreview' $SRC --include=*.swift && bad "the battery preview button / notification is back"
grep -q 'bluetooth3DKey' $SRC/App/MainWindowView.swift || bad "Settings > Bluetooth has no switch for the 3D device renders, so the crash guard can switch them off for good"

# v540. Face Lock shows its Glance credit (MIT needs the notice), the intro's Show button vanishes after one click, and the
#       intro plays again after every update (it remembers the build, not just "played once").
[ -f $SRC/App/Credits.swift ] || bad "the Credits file (Glance licence notice) is gone"
grep -q 'FaceLockCredit()' $SRC/FaceLock/FaceLockPage.swift || bad "the Face Lock page no longer shows the Glance credit"
grep -q 'introButtonUsedKey' $SRC/App/MainWindowView.swift || bad "the intro Show button no longer vanishes after one click"
grep -q 'indraWelcomePlayedBuild' $SRC/Notch/NotchWindowController.swift || bad "the intro no longer plays again after an update"

# v541. App Lock: an unlock belongs to the PROCESS that was unlocked (pid + launch date), not to the pid alone, and is dropped when
#       that process is gone. A window that was closed (not minimized) usually stays in the window list off screen, so "no window
#       left" alone never fired and a closed-then-reopened app showed without asking: the window count must also look at what is
#       ON screen, and an app in front with nothing on screen is locked again.
grep -q 'struct UnlockSession' $SRC/FaceLock/AppLock/AppLockSession.swift || bad "App Lock's unlock is no longer tied to the process (UnlockSession is gone)"
grep -q 'private var unlocked: \[pid_t: UnlockSession\]' $SRC/FaceLock/AppLock/AppLockController.swift || bad "AppLockController keeps unlocks by pid alone again"
grep -q 'isSameProcess' $SRC/FaceLock/AppLock/AppLockController.swift || bad "AppLockController no longer checks that an unlock belongs to the same process"
grep -q 'didLaunchApplicationNotification' $SRC/FaceLock/AppLock/AppLockController.swift || bad "AppLockController no longer drops an old unlock when an app is launched again"
grep -q 'kCGWindowIsOnscreen' $SRC/FaceLock/AppLock/AppLockController.swift || bad "App Lock's window count no longer separates windows on screen from kept-but-closed ones"
grep -q 'windowsClosedWhileInFront' $SRC/FaceLock/AppLock/AppLockController.swift || bad "App Lock no longer locks an app again when its windows were closed while it stayed running"
grep -q 'unlocked\[pid\] == nil, let app = NSRunningApplication' $SRC/FaceLock/AppLock/AppLockController.swift && bad "lockIfNeeded trusts an unlock by pid alone again"

# v541. The volume overlay aside, the brightness and keyboard backlight overlays show ONLY for a brightness / backlight key or a drag
#       of the Control Center / System Settings slider. Typing, trackpad movement or a click anywhere used to count as "yours", so
#       adaptive brightness and the automatic backlight brought the overlay up while working.
grep -q 'pointerIsOnSystemSlider' $SRC/Sensory/SensoryMonitor.swift || bad "the brightness / backlight overlay no longer needs a key or the system slider"
grep -q 'keyWasPressed(.brightness)' $SRC/Sensory/SensoryMonitor.swift || bad "handleBrightness no longer requires a brightness key or a slider drag"
sed -n '/private func handleBrightness/,/^    }/p;/private func handleKeyboard/,/^    }/p' $SRC/Sensory/SensoryMonitor.swift | grep -q 'isManualChange' && bad "brightness / backlight overlays use the 'any input counts' rule again (adaptive brightness shows the overlay)"

# v541. The "Notch curve follows the vinyl" option is gone for good: with the record open the corners always follow the disc.
grep -rq 'vinylCurveKey\|vinylNotchCurve' $SRC --include=*.swift && bad "the 'Notch curve follows the vinyl' option is back"

# v542. App Lock: a locked app that is opened is covered whatever its activation policy says at that moment, a launched locked app is
#       watched until it is in front, and a half-second safety net covers one the activation skipped.
grep -q 'armLaunchCover' $SRC/FaceLock/AppLock/AppLockController.swift || bad "App Lock no longer watches a launched locked app until it is in front"
grep -q 'safety net covered' $SRC/FaceLock/AppLock/AppLockController.swift || bad "App Lock's safety net for a skipped activation is gone"
grep -q 'guard regular else { return }' $SRC/FaceLock/AppLock/AppLockController.swift && bad "App Lock skips a locked app again just because it reports a background policy"

# v543. WHOLE-MAC FREEZE (cursor, keyboard and display dead, hard shutdown, after sending a file with Blip). The trackpad motor is driven
#       through a PRIVATE driver that is shared with the keyboard and the cursor. The old code renewed (closed and reopened) the
#       handles of that device whenever one handle refused a tap, i.e. on every tap while a file was dragged over the drop buttons.
#       Never again: no renewal on a refused tap, at most one renewal every 15 s, a stop for the run after too many, and the
#       whole private path is switched off after an abrupt end of the previous run.
grep -q 'stopMotorForThisRun' $SRC/App/TrackpadActuator.swift || bad "the trackpad motor has no stop for repeated renewals any more"
grep -q 'rebuildTimes' $SRC/App/TrackpadActuator.swift || bad "the trackpad motor's renewal limit is gone"
grep -q 'if fired, refused { needsRebuild = true }' $SRC/App/TrackpadActuator.swift && bad "one refusing handle renews every handle again (driver churn froze the Mac)"
grep -q 'open afresh once and try again' $SRC/App/TrackpadActuator.swift && bad "a refused tap renews the motor and taps again (driver churn froze the Mac)"
grep -q 'guard Preferences.strongHaptics' $SRC/App/TrackpadActuator.swift || bad "the trackpad motor ignores the full-strength haptics switch"
grep -q 'strongHapticsKey' $SRC/App/Diagnostics.swift || bad "an abrupt end of the last run no longer switches the private trackpad motor off"
grep -q 'IndraLog.cleanExit()   // v543' $SRC/AppDelegate.swift || bad "a shutdown or restart is counted as an abrupt end again"

# v543. App Lock: the edge light belongs to the blur cover (on its screen, only while it is on screen), the glare deny cue ignores the
#       highlights the edge light itself makes, a scan can never run on as a bare animation, and App Lock has its sounds.
grep -q 'scanningCoverScreen' $SRC/FaceLock/RingLight.swift || bad "the edge light no longer needs the blur cover on its screen"
grep -q 'scanningCoverScreen' $SRC/FaceLock/RingLightGuard.swift || bad "the edge light guard no longer needs the blur cover"
grep -q 'ignoreGlare: ringLit' $SRC/FaceLock/AppLock/FaceUnlockCoordinator+AppLock.swift || bad "the glare check rejects the owner because of the edge light again"
grep -q 'watchScan(generation: generation)' $SRC/FaceLock/AppLock/AppLockOverlay.swift || bad "App Lock's scan watchdog is gone (animation without a scan)"
grep -q 'LockSounds.playAppUnlocked()' $SRC/FaceLock/AppLock/AppLockOverlay.swift || bad "App Lock lost its unlock sound"
grep -q 'LockSounds.playAppFailed()' $SRC/FaceLock/AppLock/AppLockOverlay.swift || bad "App Lock lost its failed-unlock sound"
grep -rq 'title: "Ask for fingerprint or password to open this section"' $SRC --include=*.swift && bad "the 'Ask for fingerprint or password' option is back (it is always on)"

# v544. THE WHOLE-MAC FREEZE after a send to Blip. Indra must never look inside ANOTHER process while it works: no open-file lists
#       (proc_pidfdinfo waits inside the kernel for the file system), no window lists of that process (a window-server round trip).
#       The private trackpad driver is left alone (quiet window) from the first moment of a file drag until well after a send, and
#       the steps of a drop and a send go to the fsync'ed freeze trail, so a freeze that still happens names its last step.
hits=$(grep -nE 'proc_pidfdinfo|PROC_PIDLISTFDS|PROC_PIDFDVNODEPATHINFO|CGWindowListCopyWindowInfo' $SRC/Tray/FileSharing.swift)
[ -n "$hits" ] && bad "FileSharing looks into another process again (the whole-Mac freeze)" "$hits"
grep -q 'stayQuiet(for: 180, why: "send to Blip")' $SRC/Tray/FileSharing.swift || bad "a send to Blip no longer silences the private trackpad driver"
grep -q 'stayQuiet(for: 180, why: "send to AirDrop")' $SRC/Tray/FileSharing.swift || bad "a send to AirDrop no longer silences the private trackpad driver"
grep -q 'stayQuiet(for: 60, why: "file drag")' $SRC/Notch/NotchWindowController.swift || bad "a file drag no longer silences the private trackpad driver"
grep -q 'stayQuiet(for: 180, why: "file drop")' $SRC/Notch/NotchWindowController.swift || bad "a file drop no longer silences the private trackpad driver"
grep -q 'if isQuiet {' $SRC/App/TrackpadActuator.swift || bad "TrackpadActuator.fire ignores the quiet window"
grep -q 'F_FULLFSYNC' $SRC/App/FreezeTrail.swift || bad "the freeze trail is no longer forced to disk"
grep -q 'as? Bool ?? false' $SRC/Settings/Preferences.swift || true

# v544. A face / password that did not unlock plays its double tap quickly (0.09 s apart), App Lock finds a reopened locked app by itself.
grep -q 'now() + 0.09' $SRC/Lock/LockSounds.swift || bad "the failed-unlock double tap is slow again"
grep -q 'detectNewLockedLaunches()' $SRC/FaceLock/AppLock/AppLockController.swift || bad "App Lock no longer detects a reopened locked app on its own"

# v544. The in-app updater never waits on the main thread and uses the Mac's own git login (no token inside Indra).
grep -qiE 'ghp_|github_pat_' -r $SRC --include=*.swift && bad "a GitHub token is written into the source"

# v545. An unlocked app that turned into a background process (WhatsApp after Cmd+Q keeps its pid) is locked again.
grep -q 'relockBackgroundedApps()' $SRC/FaceLock/AppLock/AppLockController.swift || bad "App Lock no longer relocks an app that was quit to the background"

# v546. THE FREEZE AFTER "blip: handed to Blip": Blip / AirDrop are opened only after the drag is completely over (never inside the
#       drop callback), no window is moved between Spaces during the hand-off, Blip is not inspected in its first 30 s, and the
#       freeze trail has a heartbeat so the next freeze says whether Indra or the whole Mac stopped.
grep -q 'afterDragEnded {' $SRC/Tray/FileSharing.swift || bad "Blip / AirDrop are launched inside the drop callback again"
n=$(grep -c 'afterDragEnded {' $SRC/Tray/FileSharing.swift); [ "$n" -ge 2 ] || bad "AirDrop or Blip is no longer started after the drag ended"
grep -q 'isHandingOff' $SRC/Notch/NotchWindowController.swift || bad "the notch moves windows between Spaces during a Blip / AirDrop hand-off again"
grep -q 'beginHeartbeat' $SRC/Tray/FileSharing.swift || bad "the freeze trail heartbeat is no longer started by a send"
# v546. The updater signs in with a token from the Keychain (never from the source, never on a command line) and says what is missing.
grep -q 'GIT_CONFIG_VALUE_0' $SRC/Update/UpdateManager.swift || bad "the updater no longer uses the Keychain token for git"
grep -qE 'extraheader.*\\\(' $SRC/Update/UpdateManager.swift && bad "the updater puts the token into a command line"
grep -q 'INDRA_ERR no-git' $SRC/Update/UpdateManager.swift || bad "the updater no longer says when git or Xcode is missing"

# v547. Screen Recording permission is read and requested only through ScreenAccess (a background task with a cached answer): asking
#       the TCC service from the notch's code waited on the main thread ("Indra stopped responding" on a Mac without the permission).
hits=$(grep -rnE 'CGPreflightScreenCaptureAccess|CGRequestScreenCaptureAccess' $SRC --include=*.swift | grep -vE 'App/ScreenAccess.swift|Identify/SystemAudioCapture.swift')
[ -n "$hits" ] && bad "Screen Recording permission asked outside ScreenAccess (it can wait on the main thread)" "$hits"
# v547. A freeze report says where the main thread waited, and a sleeping Mac is not a freeze.
grep -q 'sampleMainThread()' $SRC/App/Diagnostics.swift || bad "the freeze report no longer includes what the main thread was doing"
# v547. The session item in the menu bar menu shows a closed padlock while the session is locked.
grep -q 'unlocked ? "lock.open.fill" : "lock.fill"' $SRC/FaceLock/FaceLockMenuBar.swift || bad "the menu bar session symbol no longer shows the locked state"

# v548. Any Mac updates from inside the app: the public feed comes first (no git, no Xcode, no token), the download is checked
#       against its SHA-256, and scripts/release.sh publishes it. Freezes leave the previous run's last steps and system log behind.
grep -q 'fetchFeed()' $SRC/Update/UpdateManager.swift || bad "the updater no longer looks at the public feed first"
grep -q 'sha256(of: zip)' $SRC/Update/UpdateManager.swift || bad "the updater no longer checks the downloaded file against its SHA-256"
[ -x scripts/release.sh ] || bad "scripts/release.sh (publishes the build the updater downloads) is gone or not executable"
grep -q 'Postmortem.capture' $SRC/App/Diagnostics.swift || bad "an abrupt end no longer saves the system log of the last run"
grep -q 'previousRunTail' $SRC/App/Diagnostics.swift || bad "an abrupt end no longer shows the last steps of the freeze trail"
[ -x scripts/freeze-forensics.sh ] || bad "scripts/freeze-forensics.sh is gone or not executable"

grep -q 'openInBlip(files' $SRC/Tray/FileSharing.swift || bad "Blip is launched from the main thread again (it is opened by the open tool in its own process)"

# v549. The GitHub token row and the "paste a token" message are for the developer only (behind DeveloperAccess), and the developer
#       code is never in the source: only its SHA-256.
grep -q 'if developerOn {' $SRC/App/AboutPage.swift || bad "the GitHub token row is visible to everybody again"
grep -q 'guard DeveloperAccess.isUnlocked' $SRC/Update/UpdateManager.swift || bad "an ordinary Mac is told to paste a GitHub token again"
grep -q 'SHA256.hash' $SRC/App/DeveloperAccess.swift || bad "the developer code is no longer kept as a hash"

# v552. Indra no longer closes Blip: the "Close Blip after sending" option and the watch of the Blip process are removed, so nothing looks
#       at another process while it sends.
grep -rq 'BlipCloser' $SRC && bad "Indra watches and closes Blip again (removed in v552)"
grep -rq 'blipAutoClose' $SRC && bad "the Close Blip after sending option is back (removed in v552)"

# v553. Updates: always looked for (no switch), a stale cache cannot hide a new version, the update quits without the fingerprint question,
#       and Blip is handed its files after the drag has ended and after the open tool's answer is read.
grep -rq 'updateAutoCheck' $SRC && bad "the Check for updates automatically switch is back (removed in v553)"
grep -q 'releasesAPI' $SRC/Update/UpdateManager.swift || bad "the updater no longer asks GitHub which release is newest (stale cache)"
grep -q 'checkInterval: TimeInterval = 10 \* 60' $SRC/Update/UpdateManager.swift || bad "the updater no longer looks every 10 minutes"
grep -q 'quittingForUpdate' $SRC/AppDelegate.swift || bad "an update quit asks for a fingerprint again (the update never ran)"
grep -q 'runOpen(app:' $SRC/Tray/FileSharing.swift || bad "Blip hand-off no longer reads the open tool's answer / retries"
grep -q 'addingTimeInterval(20 \* 60)' $SRC/Tray/DesktopCopyGuard.swift || bad "a Desktop file used by a share is moved back too early again"

# v554. A dropped folder or app (Indra.app) goes to Blip / AirDrop as ONE zip: both senders failed on a package ("Sending to ... failed:
#       Unknown error" and Blip's "unexpected error (error code -8060)"). The zip is made by a separate process in the background, never
#       waited for on the main thread, and a file that cannot be found is never handed to Blip / AirDrop.
grep -q 'DropArchive.prepared(usable' $SRC/Tray/FileSharing.swift || bad "a dropped folder / app is no longer sent to Blip / AirDrop as a zip"
grep -q 'zip: .foldersAndPackages' $SRC/Tray/FileSharing.swift || bad "Blip no longer gets folders and apps as a zip"
grep -q 'zip: .packagesOnly' $SRC/Tray/FileSharing.swift || bad "AirDrop no longer gets apps (packages) as a zip"
grep -q '/usr/bin/ditto' $SRC/Tray/DropArchive.swift || bad "the zip is no longer made by the system's ditto tool"
grep -qE 'waitUntilExit|Thread.sleep|DispatchSemaphore' $SRC/Tray/DropArchive.swift && bad "DropArchive waits for its process (it must never block a thread)"
grep -q 'nothing was sent' $SRC/Tray/FileSharing.swift || bad "a file that cannot be found is handed to Blip / AirDrop again (their error windows)"
grep -q 'AIRDROP failed' $SRC/Tray/FileSharing.swift || bad "AirDrop's own reason for a failed send is no longer written to the trace"

# v555. The face scan notch: its mouse-flag work is not repeated on every animation frame, the Tile is as wide as the volume card, and the
#       volume / brightness bar goes to the left edge while the face scan animation owns the notch above an App Lock blur screen.
grep -q 'if cursorPollTimer == nil { updateMousePassthrough() }' $SRC/FaceLock/NotchOverlay/FaceScanWindowController.swift || bad "the face scan window asks the window server about the mouse on every animation frame again"
grep -q 'metrics.hudDownlineSize.width - NotchGeometry.openTopRadius' $SRC/FaceLock/NotchOverlay/NotchOverlayView.swift || bad "the Tile scan is no longer as wide as the volume card"
grep -q 'holdEdgeHUD(event, showBar:' $SRC/Notch/NotchWindowController.swift || bad "the volume bar is no longer moved to the left edge while the face scan animation plays over a blur screen"
grep -q 'AppleHUDController(edge: .left)' $SRC/Notch/NotchWindowController.swift || bad "the left-edge volume bar is gone"
grep -q 'edgeHUD?.shutdown()' $SRC/Notch/NotchWindowController.swift || bad "the left-edge volume bar is not cleaned up in shutdown()"

# v556. The inline volume / brightness bar is never cut off: the window is made wide enough first (also when the state already says
#       "wide"), and the notch starts to widen one moment after that.
grep -q 'let tooNarrow = frame(for: closedWindowSize' $SRC/Notch/NotchWindowController.swift || bad "the closed window is no longer enlarged when it is narrower than the notch will be"
grep -q 'liveGrowTask = Task' $SRC/Notch/NotchWindowController.swift || bad "the inline volume bar no longer waits for its window to grow"

# v558. The zip of a dropped app / folder has a second way of being made (/usr/bin/zip after ditto), and what the tools say is written to the
#       trace, so a send that still shows the raw app in AirDrop / Blip says why. Their error output goes to a file, never a pipe.
grep -q '/usr/bin/zip' $SRC/Tray/DropArchive.swift || bad "the zip of a dropped app has no second method any more"
grep -q 'could not zip' $SRC/Tray/DropArchive.swift || bad "a failed zip of a dropped app is no longer written to the trace"
grep -q 'SHARE: open exited' $SRC/Tray/FileSharing.swift || bad "the answer of the open tool is no longer written to the trace when it fails"
grep -qE 'Pipe\(\)' $SRC/Tray/DropArchive.swift $SRC/Tray/FileSharing.swift && bad "a pipe is used for a tool's output in the share code (it can fill up and hold the tool)"

# v559. The left-edge volume bar keeps the size of the reference picture: 48 x 148 points, a full capsule, 12.5 from the left edge.
grep -q 'leftBarSize = CGSize(width: 48, height: 148)' $SRC/Sensory/AppleStyleHUD.swift || bad "the left-edge volume bar is no longer 48 x 148 points"
grep -q 'leftBarMargin: CGFloat = 12.5' $SRC/Sensory/AppleStyleHUD.swift || bad "the left-edge volume bar is no longer 12.5 points from the screen's edge"

# v560. No volume / brightness display while the face scan animation is on screen, to the last moment of its collapse, whether or not a blur
#       cover is still up (on success the cover goes first).
grep -q 'if case .hud = activity, faceScanBusy, !isIsland { return }' $SRC/Notch/NotchWindowController.swift || bad "a volume / brightness card can start while the face scan animation is on screen"
grep -q 'faceScanBusy || edgeHUDEvent != nil' $SRC/Notch/NotchWindowController.swift || bad "the volume bar is shown at the notch again while the face scan animation collapses"
grep -q 'appleHUD.hide()' $SRC/Notch/NotchWindowController.swift || bad "the Apple-style bar stays on screen when the face scan animation starts"

# v562. Coming back to a locked app that was out of focus never asks again before the time set in Settings: "no window on the screen" only
#       means "closed" for a window that was seen on the screen while the app was in front (not for another Space, a minimized or
#       un-hidden window). Every reason an unlock is removed is written to the trace.
grep -q 'visibleWhileFront.contains(pid)' $SRC/FaceLock/AppLock/AppLockController.swift || bad "an app is locked again for 'no window on screen' that was never seen on screen while in front"
grep -q 'out of focus for' $SRC/FaceLock/AppLock/AppLockController.swift || bad "the out-of-focus relock no longer says why in the trace"

# v563. macOS 27: the drag pasteboard is synchronised before it is read, and the pointer is kept below the menu bar while the drop zones are
#       open (a file drag lingering in the menu bar starts Mission Control there). The functions are looked up by name, never linked.
grep -q 'DragPasteboard.changeCount()' $SRC/Notch/NotchWindowController.swift || bad "the drag pasteboard is read without being synchronised (macOS 27 keeps the old count)"
grep -q 'NSPasteboard(name: .drag).changeCount' $SRC/Notch/NotchWindowController.swift && bad "the drag pasteboard count is read directly again (stale on macOS 27)"
grep -q 'holdPointerBelowMenuBar(mouse)' $SRC/Notch/NotchWindowController.swift || bad "a file drag over the drop zones can reach the menu bar again (Mission Control on macOS 27)"
grep -q 'dlsym' $SRC/Tray/DragPasteboard.swift || bad "the Pasteboard Manager functions are no longer looked up by name"
# v563. The notch window's notification observers are all removed by shutdown() (none is registered with a plain addObserver).
grep -nE '^\s+NotificationCenter\.default\.addObserver\(forName:' $SRC/Notch/NotchWindowController.swift | grep -v 'looseObservers\|token' && bad "an observer of the notch window is registered without being tracked (it is never removed)"
# v563. The inline volume bar's width is verified after its spring; one song card per song change (it waits for the new title).
grep -q 'verifyInlineHUDWidth()' $SRC/Notch/NotchWindowController.swift || bad "the inline volume bar's width is no longer verified after it opens"
grep -q 'titleStillOld' $SRC/Media/MediaController.swift || bad "the song card can show the song that just ended again"

# v564. Media from any browser: a report macOS sends with parts missing is completed from the one before (so the cover, the length and the
#       slider survive moving the slider), the cover reaches the player with every update, any Chromium-based browser is recognised, and
#       the same song announcing more details keeps its cover and gets no second song card.
grep -q 'func completed(from previous: SystemPlayback)' $SRC/Media/SystemNowPlaying.swift || bad "partial now-playing reports are no longer completed from the one before"
grep -q 'onPlayback?(merged)' $SRC/Media/SystemNowPlaying.swift || bad "the player gets the unmerged report again (the cover only arrives once)"
grep -q 'isRefinement(from: trackBefore, to: info)' $SRC/Media/MediaController.swift || bad "a song that only announces its artist / album loses its cover again"
grep -q 'CrProductDirName' $SRC/Media/YouTubeProbe.swift || bad "Chromium-based browsers that are not in the list are no longer recognised"
grep -q 'company.thebrowser.dia' $SRC/Media/YouTubeProbe.swift || bad "Dia is no longer in the browser list"
# v564. The lock screen's macOS pop-up is also kept away without the main thread (the key tap's own thread).
grep -q 'suppressWithoutMainThread()' $SRC/Sensory/SystemKeyInterceptor.swift || bad "a key the tap could not decode in time on the lock screen no longer keeps macOS's pop-up away"

# v565. The update check also reads the list of releases, uses the Mac's own GitHub login (gh) and SSH when https is refused, and says what the
#       feed answered. The lock screen's Background defaults (blur 20, darkness 0.14, video not blurred) and the menu bar icon (the notch only).
grep -q 'fetchFromReleaseList()' $SRC/Update/UpdateManager.swift || bad "the update check no longer looks through the list of releases"
grep -q 'shellGitLogin' $SRC/Update/UpdateManager.swift || bad "the update scripts no longer use the GitHub login of this Mac"
grep -q 'lockBackdropBlurDefault = 20.0' $SRC/Settings/Preferences.swift || bad "the Album blur default is not 20 any more"
grep -q 'lockBackdropDarknessDefault = 0.14' $SRC/Settings/Preferences.swift || bad "the Darkness default is not 0.14 any more"
grep -q 'lockBlurVideoDefault = false' $SRC/Settings/Preferences.swift || bad "'Blur the video' is on by default again"
grep -q '24.0 / 82.0' $SRC/FaceLock/MenuBarIconTinter.swift || bad "the menu bar icon is no longer sized by the notch alone"

[ $fail -eq 0 ] && echo "guard: all checks passed" || { echo "guard: FAILED"; exit 1; }
