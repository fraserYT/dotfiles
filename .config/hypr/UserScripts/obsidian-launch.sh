#!/usr/bin/env bash
# obsidian-launch.sh — gated Obsidian AppImage launcher (work laptop / DixieFlatline)
#
# Why this exists:
#   Obsidian Sync disconnects on every reboot and has to be manually
#   reconnected. Hyprland's exec-once fires the instant the compositor loads,
#   racing NetworkManager and the gnome-keyring Secret Service. Two earlier
#   gates (nm-online, then a D-Bus wait for org.freedesktop.secrets) fixed the
#   plaintext-keyring popup but the Sync drop still recurs, and the Obsidian
#   main-process log never records the Sync websocket — so there is no evidence
#   of which leg fails at boot.
#
# What it does:
#   1. Waits for NetworkManager startup completion.
#   2. Waits for the Secret Service to own its bus name (no D-Bus activation).
#   3. Waits for real HTTPS reachability of the Obsidian API — the leg
#      nm-online does not cover (DNS/routing can lag NM "connected").
#   4. Records every leg's result and timing, then launches Obsidian with
#      stdout/stderr captured, so the next reboot shows which gate was the
#      slow/failing one.
#
# Log: ~/.local/state/obsidian-launch.log (trimmed to the last 2000 lines per run)

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG="$LOG_DIR/obsidian-launch.log"
APPIMAGE="/home/fraser/AppImages/obsidian.appimage"

mkdir -p "$LOG_DIR"

# Keep the log bounded — trim to the last 2000 lines before appending this run.
if [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -gt 2000 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

log() { printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"; }

START=$SECONDS
log "=== launch start (boot uptime $(cut -d' ' -f1 /proc/uptime)s) ==="

# --- Leg 1: network ---------------------------------------------------------
# nm-online -s waits for NM to report startup complete (all autoconnect
# devices settled), not merely for a carrier.
nm-online -s -q -t 30
log "leg1 nm-online exit=$? elapsed=$((SECONDS - START))s"

# --- Leg 2: Secret Service --------------------------------------------------
# GetNameOwner checks ownership without triggering D-Bus activation, so this
# does not itself start a keyring daemon. Breaks the moment the name is owned.
SECRETS_OK=0
for _ in $(seq 1 60); do
    if gdbus call --session \
        --dest org.freedesktop.DBus \
        --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner \
        org.freedesktop.secrets >/dev/null 2>&1; then
        SECRETS_OK=1
        break
    fi
    sleep 0.5
done
log "leg2 secrets_owned=$SECRETS_OK elapsed=$((SECONDS - START))s"

# Ownership is not the same as usable: an unlocked login collection is what
# Electron's safeStorage actually needs to decrypt the stored Sync token.
# Logged rather than waited on — if this ever reads 'true' at launch we have
# our culprit.
LOCKED=$(busctl --user get-property \
    org.freedesktop.secrets \
    /org/freedesktop/secrets/collection/login \
    org.freedesktop.Secret.Collection Locked 2>&1)
OWNER_PID=$(busctl --user call \
    org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus \
    GetConnectionUnixProcessID s "$(gdbus call --session \
        --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetNameOwner org.freedesktop.secrets \
        2>/dev/null | tr -d "(',)" )" 2>&1 | tail -1)
log "leg2 login_collection_Locked=$LOCKED secrets_owner_pid=$OWNER_PID"

# --- Leg 3: actual reachability ---------------------------------------------
# No -f: any HTTP response (including 404) proves DNS + route + TLS all work,
# which is what the Sync websocket needs. Bounded at ~30s.
REACH_OK=0
for _ in $(seq 1 30); do
    if curl -s -m 3 -o /dev/null https://api.obsidian.md/ 2>/dev/null; then
        REACH_OK=1
        break
    fi
    sleep 1
done
log "leg3 api_reachable=$REACH_OK elapsed=$((SECONDS - START))s"

log "launching $APPIMAGE"
exec env DESKTOPINTEGRATION=1 "$APPIMAGE" --no-sandbox >>"$LOG" 2>&1
