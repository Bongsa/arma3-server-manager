#!/usr/bin/env bash

steamcmd_binary() { printf '%s/steamcmd.sh\n' "$STEAMCMD_DIR"; }

run_steamcmd_isolated() {
    env -u LD_PRELOAD \
        -u STEAM_COMPAT_CLIENT_INSTALL_PATH \
        -u STEAM_COMPAT_DATA_PATH \
        -u STEAM_RUNTIME \
        -u STEAM_RUNTIME_PREFER_HOST_LIBRARIES \
        HOME="$STEAMCMD_HOME" \
        XDG_DATA_HOME="$STEAMCMD_HOME/.local/share" \
        "$@"
}

steamcmd_output_filter() {
    local output=$1 line lower percent whole phase filled empty filled_bar empty_bar bar
    local width=30 interactive=false rendered=false is_progress=false
    if [[ ${SHOW_PROGRESS:-true} == true && -t 2 ]]; then interactive=true; fi
    while IFS= read -r line || [[ -n $line ]]; do
        printf '%s\n' "$line" >>"$output"
        is_progress=false
        if [[ $line =~ [Pp]rogress:[[:space:]]*([0-9]+([.][0-9]+)?) ]]; then
            percent=${BASH_REMATCH[1]}
            is_progress=true
        elif [[ $line =~ \[[[:space:]]*([0-9]+([.][0-9]+)?)[%]\] ]]; then
            percent=${BASH_REMATCH[1]}
            is_progress=true
        fi
        if [[ $interactive == true && $is_progress == true ]]; then
            whole=$((10#${percent%%.*}))
            if ((whole > 100)); then whole=100; fi
            lower=${line,,}
            # Recognize both English and German SteamCMD phase labels while
            # keeping all manager-generated output in English.
            case $lower in
                *download*|*herunter*) phase=Download;;
                *verif*|*ueberpruef*|*überprüf*) phase=Validation;;
                *prealloc*|*vorbereit*|*reserv*) phase=Preparation;;
                *unpack*|*entpack*) phase=Unpacking;;
                *commit*|*install*) phase=Installation;;
                *reconfig*|*konfig*) phase=Configuration;;
                *) phase=SteamCMD;;
            esac
            filled=$((whole * width / 100))
            empty=$((width - filled))
            printf -v filled_bar '%*s' "$filled" ''
            printf -v empty_bar '%*s' "$empty" ''
            filled_bar=${filled_bar// /#}
            empty_bar=${empty_bar// /-}
            bar=$filled_bar$empty_bar
            printf '\r[STEAM] %-12s [%s] %6s%%' "$phase" "$bar" "$percent" >&2
            rendered=true
            continue
        fi
        if [[ $rendered == true ]]; then printf '\n' >&2; rendered=false; fi
        printf '%s\n' "$line" >&2
    done
    [[ $rendered == false ]] || printf '\n' >&2
}

steamcmd_authenticate() {
    local steamcmd=$1 status
    if [[ ${STEAMCMD_AUTHENTICATED:-false} == true ]]; then
        return 0
    fi
    # SteamCMD displays password and Steam Guard prompts reliably only on a real
    # terminal. This phase is therefore intentionally neither piped nor logged.
    if [[ -t 0 && -t 1 ]]; then
        info "SteamCMD login: password and Steam Guard prompts will appear directly in the terminal"
        set +e
        (cd -- "$STEAMCMD_DIR" && run_steamcmd_isolated "$steamcmd" +login "$STEAM_USER" +quit)
        status=$?
        set -e
        ((status == 0)) || die "Interactive SteamCMD login failed" 77
    else
        debug "No interactive terminal; using the cached SteamCMD session"
    fi
    STEAMCMD_AUTHENTICATED=true
}

install_steamcmd() {
    local archive
    if [[ -x $(steamcmd_binary) ]]; then
        debug "SteamCMD is already installed"
        prepare_workshop_storage
        return 0
    fi
    require_commands curl tar
    init_layout
    check_free_space "$STEAMCMD_DIR"
    archive=$(mktemp "${TMPDIR:-/tmp}/steamcmd.XXXXXX.tar.gz")
    trap 'rm -f -- "$archive"' RETURN
    info "Downloading SteamCMD from Valve"
    if [[ $DRY_RUN == true ]]; then
        log DRY-RUN "curl --fail --location --output $archive [SteamCMD-URL]"
    else
        curl --fail --location --silent --show-error --output "$archive" "$STEAMCMD_URL"
        tar -xzf "$archive" -C "$STEAMCMD_DIR"
        [[ -x $(steamcmd_binary) ]] || die "SteamCMD installation is incomplete" 70
    fi
    trap - RETURN
    rm -f -- "$archive"
    prepare_workshop_storage
}

prepare_workshop_storage() {
    local isolated_workshop="$STEAMCMD_HOME/Steam/steamapps/workshop"
    local legacy_workshop="$STEAMCMD_DIR/steamapps/workshop"
    run mkdir -p -- "$STEAMCMD_HOME/Steam/steamapps" "$STEAMCMD_DIR/steamapps" "$WORKSHOP_DIR"
    ensure_workshop_root_link "$isolated_workshop"
    ensure_workshop_root_link "$legacy_workshop"
}

ensure_workshop_root_link() {
    local link_path=$1
    if [[ -L $link_path ]]; then
        if [[ $(readlink -f -- "$link_path" 2>/dev/null || true) != $(readlink -f -- "$WORKSHOP_DIR") ]]; then
            run ln -sfn -- "$WORKSHOP_DIR" "$link_path"
        fi
        return 0
    fi
    if [[ ! -e $link_path ]]; then
        run ln -s -- "$WORKSHOP_DIR" "$link_path"
        return 0
    fi
    [[ -d $link_path ]] || die "Workshop storage is not a directory: $link_path" 73
    if find "$link_path" -mindepth 1 -print -quit | grep -q .; then
        # Migrate only when WORKSHOP_DIR does not contain files or symlinks yet.
        # Empty directories created by init_layout are harmless.
        if find "$WORKSHOP_DIR" -mindepth 1 ! -type d -print -quit | grep -q .; then
            die "Workshop data exists in both $link_path and $WORKSHOP_DIR; manual merge required" 73
        fi
        if [[ $DRY_RUN == true ]]; then
            log DRY-RUN "Move Workshop data from $link_path to $WORKSHOP_DIR and replace the source with a symlink"
            return 0
        fi
        find "$WORKSHOP_DIR" -depth -mindepth 1 -type d -empty -delete
        if find "$WORKSHOP_DIR" -mindepth 1 -print -quit | grep -q .; then
            die "WORKSHOP_DIR is not empty: $WORKSHOP_DIR" 73
        fi
        rmdir -- "$WORKSHOP_DIR"
        mv -- "$link_path" "$WORKSHOP_DIR"
        ln -s -- "$WORKSHOP_DIR" "$link_path"
        info "Migrated existing isolated Workshop data to $WORKSHOP_DIR"
        return 0
    fi
    run rmdir -- "$link_path"
    run ln -s -- "$WORKSHOP_DIR" "$link_path"
}

steamcmd_run() {
    local output status=0 steamcmd
    local -a pre_login_args=()
    local -a tr_command=(tr '\r' '\n')
    local -a sed_command=(sed -u -E -e 's/(password|passphrase|two-factor code|steam guard code)[^[:cntrl:]]*/\1: [REDACTED]/Ig')
    steamcmd=$(steamcmd_binary)
    [[ -x $steamcmd ]] || die "SteamCMD is missing; run 'install' first" 69
    [[ -n $STEAM_USER ]] || die "Set STEAM_USER in config/arma3.conf" 78
    if [[ $DRY_RUN == true ]]; then
        log DRY-RUN "steamcmd +login <STEAM_USER> [redacted operation] +quit"
        return 0
    fi
    steamcmd_authenticate "$steamcmd"
    output=$(mktemp "$STATE_DIR/steamcmd.XXXXXX.log")
    # After direct authentication, this logged run uses only SteamCMD's cached
    # session. No secret is present in argv.
    info "SteamCMD is processing the requested download"
    # force_install_dir must be processed before login.
    if [[ ${1:-} == +force_install_dir ]]; then
        (($# >= 2)) || die "Missing path after +force_install_dir" 70
        pre_login_args=("$1" "$2")
        shift 2
    fi
    # Only the filter stages are unbuffered. SteamCMD itself is 32-bit and must
    # not receive the 64-bit libstdbuf through LD_PRELOAD.
    if command -v stdbuf >/dev/null 2>&1; then
        tr_command=(stdbuf -o0 tr '\r' '\n')
        sed_command=(stdbuf -oL sed -u -E -e 's/(password|passphrase|two-factor code|steam guard code)[^[:cntrl:]]*/\1: [REDACTED]/Ig')
    else
        warn "stdbuf is missing; SteamCMD progress may appear with a delay"
    fi
    set +e
    (cd -- "$STEAMCMD_DIR" && run_steamcmd_isolated "$steamcmd" \
        "${pre_login_args[@]}" +login "$STEAM_USER" "$@" +quit) 2>&1 | \
        "${tr_command[@]}" | \
        "${sed_command[@]}" | \
        steamcmd_output_filter "$output"
    status=${PIPESTATUS[0]}
    set -e
    if ((status != 0)) || grep -Eqi 'ERROR!|FAILED \(' "$output"; then
        local diagnostic
        diagnostic="$LOG_DIR/steamcmd-error-$(date +%Y%m%d-%H%M%S).log"
        install -m 0600 -- "$output" "$diagnostic"
        rm -f -- "$output"
        die "SteamCMD error${STEAM_CONTEXT:+ ($STEAM_CONTEXT)}; diagnostics: $diagnostic" 70
    fi
    rm -f -- "$output"
}

install_server_config_templates() {
    if [[ ! -e $ARMA_DIR/$SERVER_CONFIG ]]; then
        atomic_install "$PROJECT_DIR/config/server.cfg.example" "$ARMA_DIR/$SERVER_CONFIG" 0640
    fi
    if [[ ! -e $ARMA_DIR/$BASIC_CONFIG ]]; then
        atomic_install "$PROJECT_DIR/config/basic.cfg.example" "$ARMA_DIR/$BASIC_CONFIG" 0640
    fi
}

server_install() {
    init_runtime
    init_layout
    acquire_update_lock
    check_free_space "$ARMA_DIR"
    install_steamcmd
    server_is_running && die "Server is running; installation or update aborted" 75
    steamcmd_run +force_install_dir "$ARMA_DIR" +app_update "$ARMA_APP_ID" validate
    if [[ $DRY_RUN != true && ! -x $ARMA_DIR/$SERVER_BINARY ]]; then
        die "SteamCMD reported success, but $ARMA_DIR/$SERVER_BINARY is missing" 70
    fi
    install_server_config_templates
    info "Arma 3 Dedicated Server is installed and validated"
    release_update_lock
}

server_update() {
    local was_running=false
    init_runtime
    init_layout
    acquire_update_lock
    check_free_space "$ARMA_DIR"
    install_steamcmd
    if server_is_running; then
        was_running=true
        if [[ $DEFER_IF_RUNNING == true ]]; then
            warn "Server is running; server update deferred"
            release_update_lock
            return 0
        fi
        [[ $FORCE == true ]] || die "Server is running. Use --force to stop it cleanly or defer the update." 75
        server_stop
    fi
    steamcmd_run +force_install_dir "$ARMA_DIR" +app_update "$ARMA_APP_ID" validate
    [[ $DRY_RUN == true || -x $ARMA_DIR/$SERVER_BINARY ]] || die "Server binary is missing after the update" 70
    install_server_config_templates
    info "Dedicated Server updated"
    release_update_lock
    if [[ $was_running == true && $AUTO_RESTART == true ]]; then
        server_start
    elif [[ $was_running == true ]]; then
        warn "Server remains stopped because AUTO_RESTART=false"
    fi
}
