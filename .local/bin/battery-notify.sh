#!/usr/bin/env bash
# battery-notify.sh — low-battery warnings via notify-send (swaync).
# Run by systemd user timer battery-notify.timer every 2 minutes.
#
# Why this does not trust BAT1/status:
#   On this Huawei laptop the firmware reports "Charging" whenever the adapter
#   is plugged in, even when the machine is drawing more than the adapter
#   supplies and the battery is actually draining. On 2026-09-04 it fell from
#   34% to 7% as "Charging" and then lost power hard. So "draining" here means
#   EITHER status == Discharging OR capacity fell since the previous check.
#
# Thresholds: <=20% normal warning, <=10% critical, <=5% critical (repeats).
# Notifies once per threshold band per drain cycle. Bands re-arm only once
# capacity climbs REARM_MARGIN points above the last band that fired: a plain
# "capacity rose" re-arm let 21->19->21->19 wobble on a weak charger repeat
# the 20% warning (fired twice in 11 min on 2026-09-30).
#
# If no notification daemon owns org.freedesktop.Notifications (e.g. during
# shutdown, after swaync has stopped) the warning is logged, not attempted.
#
# State file holds two fields: "<last_capacity> <last_band>".
# Every run logs one line to the journal:
#   journalctl --user -u battery-notify.service
#
# Shared across machines via yadm (no ##class split); enable per machine with
#   systemctl --user enable --now battery-notify.timer
#
# Testing: point BATTERY_NOTIFY_BAT at a directory holding fake capacity and
# status files, and BATTERY_NOTIFY_STATE at a scratch state file.

set -u

# First system battery: type Battery, excluding peripherals (mice, headsets
# report scope=Device). BAT1 on DixieFlatline, likely BAT0 elsewhere. Machines
# with no battery (desktops) exit quietly below.
find_battery() {
  local d
  for d in /sys/class/power_supply/*; do
    [ "$(cat "$d/type" 2>/dev/null)" = "Battery" ] || continue
    [ "$(cat "$d/scope" 2>/dev/null)" = "Device" ] && continue
    echo "$d"
    return 0
  done
}

BAT="${BATTERY_NOTIFY_BAT:-$(find_battery)}"
STATE_FILE="${BATTERY_NOTIFY_STATE:-${XDG_RUNTIME_DIR:-/tmp}/battery-notify.state}"

[ -n "$BAT" ] && [ -r "$BAT/capacity" ] || exit 0

capacity=$(<"$BAT/capacity")
status=$(<"$BAT/status")

# Previous reading. prev_cap empty on the first run after boot.
prev_cap=""
band=100
if [ -r "$STATE_FILE" ] && read -r p b < "$STATE_FILE"; then
  prev_cap="$p"
  band="${b:-100}"
fi

# Decide whether we are actually losing charge.
draining=0
if [ "$status" = "Discharging" ]; then
  draining=1
elif [ -n "$prev_cap" ] && [ "$capacity" -lt "$prev_cap" ]; then
  draining=1
fi

# Re-arm all bands only once capacity is clearly back above the last band
# fired, so a charger that barely keeps up does not repeat the same warning.
REARM_MARGIN=5
if [ "$band" -lt 100 ] && [ "$capacity" -ge $((band + REARM_MARGIN)) ]; then
  band=100
fi

notify() { # $1=urgency $2=title $3=body
  # No daemon on the bus: notify-send would only print a GDBus error.
  if ! busctl --user status org.freedesktop.Notifications >/dev/null 2>&1; then
    echo "no notification daemon; skipped: $2"
    return 0
  fi
  notify-send --app-name=Battery --urgency="$1" --icon=battery-caution-symbolic "$2" "$3"
}

# Body suffix so a warning while "plugged in" explains itself.
if [ "$status" = "Discharging" ]; then
  why="Unplugged."
else
  why="Plugged in but the charger is not keeping up (status reads '$status')."
fi

fired=none
if [ "$draining" -eq 1 ]; then
  if [ "$capacity" -le 5 ]; then
    # Repeats every run at <=5%.
    notify critical "Battery critically low: ${capacity}%" "Save your work NOW. $why"
    band=5; fired=5
  elif [ "$capacity" -le 10 ] && [ "$band" -gt 10 ]; then
    notify critical "Battery very low: ${capacity}%" "Find a working charger soon. $why"
    band=10; fired=10
  elif [ "$capacity" -le 20 ] && [ "$band" -gt 20 ]; then
    notify normal "Battery low: ${capacity}%" "$why"
    band=20; fired=20
  fi
fi

echo "$capacity $band" > "$STATE_FILE"
echo "capacity=${capacity}% status=${status} prev=${prev_cap:-none} draining=${draining} band=${band} fired=${fired}"
exit 0
