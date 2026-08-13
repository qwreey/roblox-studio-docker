#!/usr/bin/env bash
set -u

# Replaces the old entrypoint.sh's `wait -n "${WM_PID}" "${VNC_PID}" "${DBUS_PID}"`: the
# container must exit if labwc, wayvnc, or dbus ever stops, for any reason - see
# CLAUDE.md's "Conventions" section ("entrypoint.sh backgrounds each core process ... and
# `wait -n`s on just those three, so the container dies if any one of them dies").
# supervisord itself has no built-in "shut the whole stack down if program X exits"
# directive, so this program polls for it instead. dbus/labwc/wayvnc's own [program:...]
# entries set autorestart=false + startretries=0 precisely so a first failure surfaces
# here immediately rather than being quietly retried.
SUPERVISOR_SOCK="unix:///run/supervisor.sock"
CRITICAL_PROGRAMS=(dbus labwc wayvnc)

running=true
trap 'running=false' TERM INT

# Grace period: right after supervisord starts, these programs may briefly still show as
# STOPPED before supervisord gets around to actually spawning them - checking immediately
# would trip a false-positive shutdown before they ever got a chance to start.
sleep 5

while "${running}"; do
  for program in "${CRITICAL_PROGRAMS[@]}"; do
    state="$(supervisorctl -s "${SUPERVISOR_SOCK}" status "${program}" 2>/dev/null | awk '{print $2}')"
    if [[ "${state}" != "RUNNING" && "${state}" != "STARTING" ]]; then
      echo "[critical-watchdog] ${program} is not running (state=${state:-unknown}) — shutting the whole stack down"
      supervisorctl -s "${SUPERVISOR_SOCK}" shutdown >/dev/null 2>&1
      exit 0
    fi
  done
  sleep 2
done
exit 0
