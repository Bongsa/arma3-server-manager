#!/usr/bin/env bash

PROJECT_DIR=${PROJECT_DIR:?PROJECT_DIR must be set}
CONFIG_DIR=${CONFIG_DIR:-"$PROJECT_DIR/config"}
MODS_FILE=${MODS_FILE:-"$CONFIG_DIR/mods.json"}
LOCAL_MODS_FILE=${LOCAL_MODS_FILE:-"$CONFIG_DIR/local-mods.json"}
OVERRIDES_FILE=${OVERRIDES_FILE:-"$CONFIG_DIR/mod-overrides.conf"}
RUNTIME_DIR=${RUNTIME_DIR:-"$PROJECT_DIR/runtime"}
DRY_RUN=${DRY_RUN:-false}
VERBOSE=${VERBOSE:-false}
FORCE=${FORCE:-false}
DEFER_IF_RUNNING=${DEFER_IF_RUNNING:-false}
LOG_FILE=${LOG_FILE:-}

timestamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log() {
    local level=$1
    shift
    local line
    line="[$(timestamp)] [$level] $*"
    printf '%s\n' "$line" >&2
    if [[ -n ${LOG_FILE:-} ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    fi
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
die() { local message=$1 status=${2:-1}; log ERROR "$message"; exit "$status"; }
debug() { if [[ $VERBOSE == true ]]; then log DEBUG "$@"; fi; }

run() {
    if [[ $DRY_RUN == true ]]; then
        local rendered='' arg
        for arg in "$@"; do printf -v rendered '%s %q' "$rendered" "$arg"; done
        log DRY-RUN "${rendered# }"
        return 0
    fi
    "$@"
}

atomic_install() {
    local source=$1 destination=$2 mode=${3:-0644}
    local destination_dir temp
    destination_dir=$(dirname -- "$destination")
    run mkdir -p -- "$destination_dir"
    if [[ $DRY_RUN == true ]]; then
        log DRY-RUN "install -m $mode -- $source $destination"
        return 0
    fi
    temp=$(mktemp --tmpdir="$destination_dir" '.arma3-manager.XXXXXX')
    trap 'rm -f -- "$temp"' RETURN
    install -m "$mode" -- "$source" "$temp"
    mv -fT -- "$temp" "$destination"
    trap - RETURN
}

require_commands() {
    local missing=() command
    for command in "$@"; do command -v "$command" >/dev/null 2>&1 || missing+=("$command"); done
    ((${#missing[@]} == 0)) || die "Missing required commands: ${missing[*]}" 69
}

validate_config() {
    [[ $ARMA_APP_ID =~ ^[0-9]+$ ]] || die "Invalid ARMA_APP_ID: $ARMA_APP_ID" 78
    [[ $WORKSHOP_APP_ID =~ ^[0-9]+$ ]] || die "Invalid WORKSHOP_APP_ID: $WORKSHOP_APP_ID" 78
    if [[ ! $PORT =~ ^[0-9]+$ ]] || ((PORT < 1 || PORT > 65535)); then
        die "Invalid PORT: $PORT" 78
    fi
    [[ $MIN_FREE_GB =~ ^[0-9]+$ ]] || die "MIN_FREE_GB must be an integer" 78
}

init_runtime() {
    local directory
    if ((EUID == 0)) && [[ ${ROOT_WARNING_SHOWN:-false} != true ]]; then
        warn "For security, run production servers as a dedicated user (for example arma3), not as root"
        ROOT_WARNING_SHOWN=true
    fi
    if [[ $DRY_RUN == true ]]; then
        STATE_DIR="$RUNTIME_DIR/dry-run-state"
        LOG_DIR="$RUNTIME_DIR/dry-run-logs"
        mkdir -p -- "$STATE_DIR" "$LOG_DIR"
    fi
    for directory in "$LOG_DIR" "$STATE_DIR" "$RUNTIME_DIR"; do
        if [[ $DRY_RUN == true ]]; then
            mkdir -p -- "$RUNTIME_DIR"
            continue
        fi
        mkdir -p -- "$directory" || die "Cannot create directory: $directory" 73
        [[ -w $directory ]] || die "Directory is not writable: $directory" 73
    done
    if [[ $DRY_RUN != true ]]; then
        LOG_FILE="$LOG_DIR/arma3-manager-$(date +%F).log"
        touch -- "$LOG_FILE" || die "Log file is not writable: $LOG_FILE" 73
        chmod 0640 -- "$LOG_FILE" 2>/dev/null || true
    fi
}

init_layout() {
    local directory
    for directory in "$ARMA_DIR" "$STEAMCMD_DIR" "$STEAMCMD_HOME" "$WORKSHOP_DIR/content/$WORKSHOP_APP_ID" \
        "$MOD_LINK_DIR" "$SERVER_MOD_LINK_DIR" "$LOG_DIR" "$PROFILE_DIR" "$STATE_DIR"; do
        run mkdir -p -- "$directory"
        if [[ $DRY_RUN != true && ! -w $directory ]]; then
            die "Directory is not writable: $directory" 73
        fi
    done
    run chmod 0700 -- "$STEAMCMD_HOME"
}

check_free_space() {
    local target=$1
    local nearest=$target available required=$((MIN_FREE_GB * 1024 * 1024))
    while [[ ! -e $nearest && $nearest != / ]]; do nearest=$(dirname -- "$nearest"); done
    available=$(df -Pk -- "$nearest" | awk 'NR==2 {print $4}')
    [[ $available =~ ^[0-9]+$ ]] || die "Could not determine free space for $target" 74
    ((available >= required)) || die "Insufficient space at $target: at least ${MIN_FREE_GB} GiB required" 75
    debug "Free space at $nearest: $((available / 1024 / 1024)) GiB"
}

acquire_update_lock() {
    require_commands flock
    if ((${UPDATE_LOCK_DEPTH:-0} > 0)); then
        ((UPDATE_LOCK_DEPTH += 1))
        return 0
    fi
    mkdir -p -- "$STATE_DIR"
    exec {UPDATE_LOCK_FD}>"$STATE_DIR/update.lock"
    flock -n "$UPDATE_LOCK_FD" || die "Another installation or update process is already running" 75
    UPDATE_LOCK_DEPTH=1
}

release_update_lock() {
    if [[ -n ${UPDATE_LOCK_FD:-} ]]; then
        if ((${UPDATE_LOCK_DEPTH:-1} > 1)); then
            ((UPDATE_LOCK_DEPTH -= 1))
            return 0
        fi
        flock -u "$UPDATE_LOCK_FD" 2>/dev/null || true
        exec {UPDATE_LOCK_FD}>&-
        unset UPDATE_LOCK_FD
        UPDATE_LOCK_DEPTH=0
    fi
}

valid_workshop_id() { [[ ${1:-} =~ ^[1-9][0-9]{4,19}$ ]]; }

effective_type() {
    local id=$1 default_type=${2:-client} line value
    if [[ -r $OVERRIDES_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%%#*}
            [[ $line == *=* ]] || continue
            if [[ ${line%%=*} == "$id" ]]; then
                value=${line#*=}
                value=${value//[[:space:]]/}
                case $value in client|server|both) printf '%s\n' "$value"; return 0;; esac
                die "Invalid override for $id: $value" 78
            fi
        done <"$OVERRIDES_FILE"
    fi
    case $default_type in
        client|server|both) printf '%s\n' "$default_type";;
        *) die "Invalid mod type for $id in $MODS_FILE: $default_type" 78;;
    esac
}

json_mod_count() { jq 'length' "$MODS_FILE"; }
