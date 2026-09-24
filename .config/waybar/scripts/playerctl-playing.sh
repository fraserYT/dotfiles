#!/usr/bin/env bash
# Feed for Waybar's custom/playerctl: same JSON as before, but a player only shows while it is
# Playing. A paused or stopped one (e.g. a YouTube Music tab left paused for hours) blanks the
# module instead of pinning its last track in the bar. Added 2026-09-24.
fmt='{{status}}	{"text": "{{artist}}  {{markup_escape(title)}}", "tooltip": "{{playerName}} : {{markup_escape(title)}}", "alt": "{{status}}", "class": "{{status}}"}'
playerctl -a metadata --format "$fmt" -F 2>/dev/null |
while IFS=$'\t' read -r status json; do
  if [ "$status" = "Playing" ]; then
    printf '%s\n' "$json"
  else
    printf '{"text": "", "class": "%s"}\n' "$status"
  fi
done
