#!/bin/bash
# Records the demo: Bupsy playing its own story, hands-free, on a seeded throwaway roster, with
# scripted runs (no real model calls). See Apps/BupsyMac/Sources/DemoMode.swift.
#
#   ./scripts/record-demo.sh                 build, record, and write the videos to ./demo-out
#   ./scripts/record-demo.sh --out DIR       write them somewhere else
#   ./scripts/record-demo.sh --dark          a dark-mode take
#   ./scripts/record-demo.sh --check         no screen recording: save a picture of the window
#                                            every half second instead, to look a take over
#   ./scripts/record-demo.sh --no-build      reuse the last build
#
# Writes bupsy-reveal.mp4 (full resolution, H.264), bupsy-reveal-1080p.mp4, and square and
# vertical cuts. Recording the screen needs macOS Screen Recording permission for whatever runs
# this script (Terminal, iTerm, your editor): System Settings › Privacy & Security › Screen &
# System Audio Recording. Without it the script stops and says so.
#
# Safe beside the real app: the demo runs as its own copy, "Bupsy Demo.app", with its own bundle
# id, so it shares no preferences, saved window state or notifications with Bupsy, and on a fresh
# throwaway home, so it never sees your bots. Everything it made is removed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

OUT="$ROOT/demo-out"
APPEARANCE=light
CHECK=0
BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift ;;
    --dark) APPEARANCE=dark ;;
    --check) CHECK=1 ;;
    --no-build) BUILD=0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

FFMPEG="$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DERIVED="${BUPSY_DEMO_DERIVED:-${TMPDIR:-/tmp}/bupsy-demo-build}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bupsy-demo-run.XXXXXX")"
HOME_DIR="$WORK/home"
DEMO_APP="$WORK/Bupsy Demo.app"
DEMO_ID=si.bupsy.mac.demo
WINDOW_SIZE="${BUPSY_DEMO_SIZE:-1360x765}"
mkdir -p "$OUT" "$HOME_DIR"

say() { printf '\033[1;35m==> %s\033[0m\n' "$1"; }
die() { printf '\033[1;31m%s\033[0m\n' "$1" >&2; exit 1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

APP_PID=""
REC_PID=""
PREFS_BEFORE="$(ls ~/Library/Preferences/ | grep '^si\.bupsy\.home\.' || true)"
cleanup() {
  [ -n "$REC_PID" ] && kill "$REC_PID" 2>/dev/null || true
  [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null || true
  [ -n "$APP_PID" ] && wait "$APP_PID" 2>/dev/null || true
  # The throwaway home's preferences suite, and anything the demo copy kept under its own id.
  for domain in $(ls ~/Library/Preferences/ | grep '^si\.bupsy\.home\.' | sed 's/\.plist$//'); do
    if ! printf '%s\n' "$PREFS_BEFORE" | grep -qx "$domain.plist"; then
      defaults delete "$domain" >/dev/null 2>&1 || true
      rm -f ~/Library/Preferences/"$domain".plist
    fi
  done
  defaults delete "$DEMO_ID" >/dev/null 2>&1 || true
  rm -rf ~/Library/Preferences/"$DEMO_ID".plist ~/Library/Saved\ Application\ State/"$DEMO_ID".savedState \
         ~/Library/Caches/"$DEMO_ID" ~/Library/HTTPStorages/"$DEMO_ID" ~/Library/WebKit/"$DEMO_ID"
  [ -d "$DEMO_APP" ] && "$LSREGISTER" -u "$DEMO_APP" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

if [ "$BUILD" = 1 ]; then
  say "Building the debug app"
  xcodegen generate >/dev/null
  xcodebuild -project Bupsy.xcodeproj -scheme BupsyMac -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build 2>&1 \
    | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
  # Building can touch the lockfile with nothing changed; leave the tree as it was.
  git diff --quiet -- Packages/BupsyKit/Package.resolved 2>/dev/null \
    || git checkout -- Packages/BupsyKit/Package.resolved 2>/dev/null || true
fi
BUILT="$DERIVED/Build/Products/Debug/Bupsy.app"
[ -d "$BUILT" ] || die "No build at $BUILT"
# Xcode registers what it builds; the demo copy is the only one that should ever open.
"$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true

ditto "$BUILT" "$DEMO_APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DEMO_ID" "$DEMO_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Bupsy" "$DEMO_APP/Contents/Info.plist" 2>/dev/null || true
codesign --force --deep --sign - "$DEMO_APP" >/dev/null 2>&1 || true

FRAME_FILE="$WORK/frame.txt"
START_FILE="$WORK/start"
DONE_FILE="$WORK/done"
SNAPSHOTS=""
[ "$CHECK" = 1 ] && SNAPSHOTS="$OUT/frames-$APPEARANCE" && rm -rf "$SNAPSHOTS"

say "Starting the demo ($APPEARANCE, window $WINDOW_SIZE)"
env BUPSY_HOME="$HOME_DIR" BUPSY_DEMO_APPEARANCE="$APPEARANCE" BUPSY_DEMO_SIZE="$WINDOW_SIZE" \
    BUPSY_DEMO_FRAME_FILE="$FRAME_FILE" BUPSY_DEMO_START_FILE="$START_FILE" \
    BUPSY_DEMO_DONE_FILE="$DONE_FILE" ${SNAPSHOTS:+BUPSY_DEMO_SNAPSHOTS="$SNAPSHOTS"} \
    "$DEMO_APP/Contents/MacOS/Bupsy" --demo --autoplay >"$WORK/app.log" 2>&1 &
APP_PID=$!

for _ in $(seq 1 300); do [ -s "$FRAME_FILE" ] && break; sleep 0.1; done
[ -s "$FRAME_FILE" ] || { cat "$WORK/app.log" >&2; die "The demo window never came up."; }
REGION="$(tr -d '\n' < "$FRAME_FILE")"
sleep 1.5   # let the first frame settle

if [ "$CHECK" = 1 ]; then
  touch "$START_FILE"
  for _ in $(seq 1 900); do [ -e "$DONE_FILE" ] && break; sleep 0.1; done
  [ -e "$DONE_FILE" ] || die "The take never finished."
  say "Done. Frames in $SNAPSHOTS"
  exit 0
fi

say "Checking Screen Recording permission"
PROBE="$WORK/probe.mov"
if ! screencapture -x -v -V1 -R"$REGION" "$PROBE" >"$WORK/probe.log" 2>&1 || [ ! -s "$PROBE" ]; then
  cat "$WORK/probe.log" >&2
  die "Couldn't record the screen. Give $(basename "${TERM_PROGRAM:-your terminal}") Screen Recording permission in
System Settings › Privacy & Security › Screen & System Audio Recording, quit and reopen it, and run
this again. Nothing was recorded."
fi

RAW="$WORK/raw.mov"
# screencapture stops on its own after this long; it ignores SIGINT when started in the background.
REC_SECONDS="${BUPSY_DEMO_RECORD_SECONDS:-45}"
say "Recording region $REGION for ${REC_SECONDS}s"
screencapture -x -v -V"$REC_SECONDS" -R"$REGION" "$RAW" >"$WORK/rec.log" 2>&1 &
REC_PID=$!
sleep 2
T_CUE=$(now)
touch "$START_FILE"
for _ in $(seq 1 900); do [ -e "$DONE_FILE" ] && break; sleep 0.05; done
T_DONE=$(now)
[ -e "$DONE_FILE" ] || die "The take never finished."
LENGTH=$(echo "$T_DONE - $T_CUE" | bc -l)
awk "BEGIN{exit !($LENGTH + 2.5 < $REC_SECONDS)}" \
  || die "The take ran ${LENGTH}s, longer than the recording. Set BUPSY_DEMO_RECORD_SECONDS higher."
wait "$REC_PID" 2>/dev/null || true
REC_PID=""
[ -s "$RAW" ] || { cat "$WORK/rec.log" >&2; die "The recording came out empty."; }
[ -n "${BUPSY_DEMO_KEEP_RAW:-}" ] && cp "$RAW" "$OUT/raw.mov"

# Where the story starts in the recording. screencapture writes a frame only when something
# changes, so the first frame after the opening one is the palette opening, which autoplay does
# 2 s after its cue. The cut starts at the cue, so the opening hold is whole.
FIRST_CHANGE=$("$FFMPEG" -hide_banner -i "$RAW" -vf "select='gt(scene,0.04)',showinfo" -an -f null - 2>&1 \
  | sed -n 's/.*pts_time:\([0-9.]*\).*/\1/p' | head -1 || true)
[ -n "$FIRST_CHANGE" ] || die "Couldn't find the story in the recording."
START=$(echo "s=$FIRST_CHANGE - 2.0; if (s < 0) s = 0; s" | bc -l)
say "Cutting ${LENGTH}s from ${START}s"

# The recording has a variable frame rate (up to 60 while things move, none while still), so it
# is made constant first, from its very start, and only then cut: cutting first lost the still
# opening hold, which has no frames of its own.
ENCODE=(-c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -movflags +faststart -an)
"$FFMPEG" -hide_banner -loglevel error -y -i "$RAW" \
  -vf "fps=60,trim=start=$START:duration=$LENGTH,setpts=PTS-STARTPTS,scale=trunc(iw/2)*2:trunc(ih/2)*2:flags=lanczos" \
  "${ENCODE[@]}" "$OUT/bupsy-reveal.mp4"
"$FFMPEG" -hide_banner -loglevel error -y -i "$OUT/bupsy-reveal.mp4" \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2" \
  "${ENCODE[@]}" "$OUT/bupsy-reveal-1080p.mp4"

# Square and vertical: the whole window, on the same ground as the backdrop, rather than a crop
# that cuts the conversation in half.
if [ "$APPEARANCE" = dark ]; then FROM=0x2B2130; TO=0x1A1A24; else FROM=0xF7E3F2; TO=0xE6E3FC; fi
# The backdrop is a 35° gradient across the recorded region; the ground continues that same
# gradient line out past the shot, so there is no seam where the two meet.
read -r RW RH < <(tr ',' ' ' <<<"$REGION" | awk '{print $3, $4}')
for shape in square:1080:1080 vertical:1080:1920; do
  IFS=: read -r name w h <<<"$shape"
  read -r X0 Y0 X1 Y1 < <(awk -v w="$w" -v h="$h" -v rw="$RW" -v rh="$RH" 'BEGIN {
    a = 35 * atan2(0, -1) / 180; sh = w * rh / rw; half = (w * cos(a) + sh * sin(a)) / 2
    printf "%d %d %d %d\n", w/2 - half*cos(a), h/2 - half*sin(a), w/2 + half*cos(a), h/2 + half*sin(a) }')
  "$FFMPEG" -hide_banner -loglevel error -y -i "$OUT/bupsy-reveal.mp4" \
    -filter_complex "gradients=s=${w}x${h}:c0=$FROM:c1=$TO:x0=$X0:y0=$Y0:x1=$X1:y1=$Y1:nb_colors=2:r=60:d=$LENGTH:speed=0[ground];
                     [0:v]scale=$w:-2:flags=lanczos[shot];[ground][shot]overlay=(W-w)/2:(H-h)/2:shortest=1" \
    "${ENCODE[@]}" "$OUT/bupsy-reveal-$name.mp4"
done

say "Done"
ls -lh "$OUT"/bupsy-reveal*.mp4
