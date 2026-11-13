#!/bin/bash
# v547: after a whole-Mac freeze and a hard restart, collects everything the Mac itself recorded, in ONE file to send back.
#   sudo scripts/freeze-forensics.sh [hours]        (default: the last 12 hours)
# The reports in /Library/Logs/DiagnosticReports are readable by root only; that is why sudo. Nothing is changed or deleted.
HOURS="${1:-12}"
USER_HOME=$(eval echo "~${SUDO_USER:-$USER}")
OUT="$USER_HOME/Desktop/indra-freeze-forensics.txt"
DIR=/Library/Logs/DiagnosticReports
APPSUP="$USER_HOME/Library/Application Support/Indra/Problems"
KEYS='Indra|Blip|WindowServer|watchdog|blocked on|stuck|hung|panic|timed out|Spin|spinning|IOHID|MultitouchSupport|SkyLight'
{
  echo "== $(date) on $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model) =="
  echo; echo "== Indra: freeze trail (last 60 lines; the LAST line is the last thing Indra did) =="
  tail -60 "$APPSUP/freeze-trail.txt" 2>/dev/null
  echo; echo "== Indra: timeline (last 40) =="; tail -40 "$APPSUP/timeline.txt" 2>/dev/null
  echo; echo "== Reports written in the last $HOURS h =="
  find "$DIR" -type f -mmin -$((HOURS*60)) -exec ls -l {} \; 2>/dev/null
  for f in $(find "$DIR" -type f \( -name 'forceReset*' -o -name 'ResetCounter*' -o -name '*.panic' -o -name '*.hang' -o -name '*.spin' -o -name '*Indra*' -o -name '*Blip*' -o -name '*WindowServer*' \) -mmin -$((HOURS*60)) 2>/dev/null); do
    echo; echo "================ $f ================"
    grep -n -i -E "$KEYS" "$f" | head -80
    echo "---- the lines around the first mention of Indra ----"
    grep -n -i -m1 -B3 -A40 'Indra' "$f" | head -90
  done
  echo; echo "== System log, last $HOURS h: faults / errors / hang words from Indra, Blip, WindowServer, kernel =="
  log show --style compact --last ${HOURS}h --predicate '(process == "Indra" OR process == "Blip" OR process == "WindowServer" OR process == "kernel" OR process == "watchdogd") AND (messageType == fault OR messageType == error OR eventMessage CONTAINS[c] "watchdog" OR eventMessage CONTAINS[c] "hang" OR eventMessage CONTAINS[c] "timed out" OR eventMessage CONTAINS[c] "stuck" OR eventMessage CONTAINS[c] "not responding")' 2>/dev/null | tail -400
  echo; echo "== Sleep / wake / power events =="
  pmset -g log 2>/dev/null | grep -E "Sleep|Wake|DarkWake|Hibernate|Shutdown|Restart|Assertions" | tail -40
} > "$OUT" 2>&1
chown "${SUDO_USER:-$USER}" "$OUT" 2>/dev/null
echo "written: $OUT  ($(wc -c < "$OUT") bytes). Send that file."
