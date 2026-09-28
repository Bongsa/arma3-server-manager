#!/usr/bin/env bash
set -eu
: "${FAKE_STEAM_CAPTURE:?}"
printf '%s\n' "$HOME" >"$FAKE_STEAM_CAPTURE"
printf '%s\n' "$@" >>"$FAKE_STEAM_CAPTURE"
printf 'Success! Fake SteamCMD completed\n'

