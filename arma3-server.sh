#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export PROJECT_DIR
CONFIG_FILE=${ARMA3_CONFIG:-"$PROJECT_DIR/config/arma3.conf"}
[[ -r $CONFIG_FILE ]] || { printf '[ERROR] Configuration file not found: %s\n' "$CONFIG_FILE" >&2; exit 78; }
# shellcheck source=config/arma3.conf
source "$CONFIG_FILE"
# shellcheck source=lib/common.sh
source "$PROJECT_DIR/lib/common.sh"
# shellcheck source=lib/steam.sh
source "$PROJECT_DIR/lib/steam.sh"
# shellcheck source=lib/preset.sh
source "$PROJECT_DIR/lib/preset.sh"
# shellcheck source=lib/lowercase.sh
source "$PROJECT_DIR/lib/lowercase.sh"
# shellcheck source=lib/mods.sh
source "$PROJECT_DIR/lib/mods.sh"
# shellcheck source=lib/local_mods.sh
source "$PROJECT_DIR/lib/local_mods.sh"
# shellcheck source=lib/keys.sh
source "$PROJECT_DIR/lib/keys.sh"
# shellcheck source=lib/server.sh
source "$PROJECT_DIR/lib/server.sh"

on_error() {
    local status=$?
    log ERROR "Aborted in ${BASH_SOURCE[1]##*/}:${BASH_LINENO[0]} (exit $status)"
    exit "$status"
}
trap on_error ERR

usage() {
    cat <<'EOF'
Arma 3 Dedicated Server Manager

Usage: ./arma3-server.sh [--verbose] [--dry-run] COMMAND [ARGUMENTS]

  install                         Install SteamCMD, the server, and configured mods
  import-preset FILE              Import an Arma Launcher HTML preset into config/mods.json
  server install                  Install the dedicated server
  server update [--force]         Update the server; --force stops it first
  mods list                       Show the imported mod list
  mods check                      Show installation and update status
  mods update [WORKSHOP_ID]       Update only missing or outdated mods
  local-mod add TYPE PATH         Add a local mod as client|server|both
  local-mod list                  Show local mods
  local-mod remove NAME           Remove a local mod from management
  local-mod sync                  Synchronize local links, keys, and launch arguments
  local-mod lowercase NAME        Explicitly lowercase a local mod source
  keys sync                       Synchronize signature keys from all installed mods
  links rebuild                   Validate and repair mod symlinks
  lowercase [WORKSHOP_ID]         Safely lowercase mod contents
  start | stop | restart | status Manage the server process
  console                         Follow the live server log
  update [--force]                Perform a complete server and mod update
  help                            Show this help

Options:
  --verbose          Show additional diagnostics
  --dry-run          Show planned changes
  --force            Stop a running server cleanly for update commands
  --defer-if-running Leave a running server untouched and defer successfully (timer)
EOF
}

args=()
for arg in "$@"; do
    case $arg in
        --verbose) VERBOSE=true;;
        --dry-run) DRY_RUN=true;;
        --force) FORCE=true;;
        --defer-if-running) DEFER_IF_RUNNING=true;;
        --help|-h) args+=(help);;
        --*) die "Unknown option: $arg" 64;;
        *) args+=("$arg");;
    esac
done
set -- "${args[@]}"

validate_config

command=${1:-help}
shift || true

case $command in
    help) usage;;
    import-preset) (($# == 1)) || die "Usage: import-preset FILE" 64; import_preset "$1";;
    install) (($# == 0)) || die "Usage: install" 64; full_install;;
    server)
        sub=${1:-}; shift || true
        (($# == 0)) || die "Too many arguments for server $sub" 64
        case $sub in install) server_install;; update) server_update;; *) die "Usage: server install|update" 64;; esac
        ;;
    mods)
        sub=${1:-}; shift || true
        case $sub in
            list) (($# == 0)) || die "Usage: mods list" 64; mods_list;;
            check) (($# == 0)) || die "Usage: mods check" 64; mods_check;;
            update) (($# <= 1)) || die "Usage: mods update [ID]" 64; mods_update "${1:-}";;
            *) die "Usage: mods list|check|update [ID]" 64;;
        esac
        ;;
    local-mod)
        sub=${1:-}; shift || true
        case $sub in
            add) (($# == 2)) || die "Usage: local-mod add client|server|both PATH" 64; local_mod_add "$1" "$2";;
            list) (($# == 0)) || die "Usage: local-mod list" 64; local_mod_list;;
            remove) (($# == 1)) || die "Usage: local-mod remove NAME" 64; local_mod_remove "$1";;
            sync) (($# == 0)) || die "Usage: local-mod sync" 64; local_mod_sync_all;;
            lowercase) (($# == 1)) || die "Usage: local-mod lowercase NAME" 64; local_mod_lowercase "$1";;
            *) die "Usage: local-mod add|list|remove|sync|lowercase" 64;;
        esac
        ;;
    keys) [[ ${1:-} == sync && $# == 1 ]] || die "Usage: keys sync" 64; keys_sync;;
    links) [[ ${1:-} == rebuild && $# == 1 ]] || die "Usage: links rebuild" 64; links_rebuild; generate_start_args;;
    lowercase) (($# <= 1)) || die "Usage: lowercase [WORKSHOP_ID]" 64; lowercase_all "${1:-}";;
    start) server_start;;
    stop) server_stop;;
    restart) server_restart;;
    status) if ! server_status; then exit 3; fi;;
    console) server_console;;
    run) server_run_foreground;;
    update) full_update;;
    *) die "Unknown command: $command (see: help)" 64;;
esac
