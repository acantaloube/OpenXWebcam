#!/bin/bash
# Run the patched OpenXWebcam with its engine log kept on disk, so a stall that
# happens hours later can still be diagnosed.
cd "$(dirname "$0")"
LOG="$HOME/fujicam/openxwebcam-$(date +%Y%m%d-%H%M%S).log"
echo "Logging to $LOG"
echo "Use the app normally. If it stalls, quit and send me that file."
OPENXWEBCAM_LOG=1 exec ./buildout/OpenXWebcam.app/Contents/MacOS/OpenXWebcam 2>&1 | tee "$LOG"
