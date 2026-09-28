#!/usr/bin/env bash

pid_file() { printf '%s/arma3server.pid\n' "$STATE_DIR"; }
server_stdout_log() { printf '%s/server-console.log\n' "$LOG_DIR"; }

server_is_running() {
    local file pid executable
    file=$(pid_file)
    [[ -r $file ]] || return 1
    read -r pid <"$file" || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    IFS= read -r -d '' executable <"/proc/$pid/cmdline" 2>/dev/null || true
    [[ $executable == "$ARMA_DIR/$SERVER_BINARY" ]]
}

ensure_link() {
    local destination=$1 target=$2
    if [[ -L $destination ]]; then
        if [[ $(readlink -f -- "$destination" 2>/dev/null || true) == $(readlink -f -- "$target") ]]; then
            return 0
        fi
        run ln -sfn -- "$target" "$destination"
    elif [[ -e $destination ]]; then
        die "Link destination is occupied by a real file or directory: $destination" 73
    else
        run ln -s -- "$target" "$destination"
    fi
}

links_rebuild() {
    local manifest="$STATE_DIR/managed-links.json" previous desired records id name declared type link target destination
    init_runtime
    # Validate before mutating any links so a newly added Workshop mod cannot
    # overwrite an already managed local link.
    local_mod_validate_workshop_collisions
    run mkdir -p -- "$MOD_LINK_DIR" "$SERVER_MOD_LINK_DIR"
    previous=$(mktemp "$STATE_DIR/links-old.XXXXXX.json")
    desired=$(mktemp "$STATE_DIR/links-new.XXXXXX.json")
    records=$(mktemp "$STATE_DIR/links.XXXXXX.tsv")
    [[ -r $manifest ]] && cp -- "$manifest" "$previous" || printf '[]\n' >"$previous"
    while IFS=$'\t' read -r id name declared link; do
        target="$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/$id"
        if [[ ! -d $target ]]; then warn "No link created for uninstalled mod $id ($name)"; continue; fi
        type=$(effective_type "$id" "$declared")
        if [[ $type == client || $type == both ]]; then
            destination="$MOD_LINK_DIR/$link"
            ensure_link "$destination" "$target"
            printf '%s\t%s\n' "$destination" "$target" >>"$records"
        fi
        if [[ $type == server || $type == both ]]; then
            destination="$SERVER_MOD_LINK_DIR/$link"
            ensure_link "$destination" "$target"
            printf '%s\t%s\n' "$destination" "$target" >>"$records"
        fi
    done < <(jq -r '.[] | [.workshop_id,.name,.type,.link_name] | @tsv' "$MODS_FILE")
    jq -Rn '[inputs | split("\t") | {destination:.[0],target:.[1]}]' <"$records" >"$desired"
    while IFS= read -r destination; do
        if ! jq -e --arg d "$destination" 'any(.[]; .destination == $d)' "$desired" >/dev/null; then
            if [[ -L $destination ]]; then run rm -- "$destination"
            elif [[ -e $destination ]]; then warn "Formerly managed link was replaced and will be retained: $destination"
            fi
        fi
    done < <(jq -r '.[].destination' "$previous")
    [[ $DRY_RUN == true ]] || atomic_install "$desired" "$manifest" 0640
    local_mod_sync_links
    info "Symlinks validated: $(jq 'length' "$desired")"
    rm -f -- "$previous" "$desired" "$records"
}

generate_start_args() {
    local output="$RUNTIME_DIR/start-args.sh" temporary id declared type link path
    local -a client_paths=() server_paths=() generated=()
    init_runtime
    while IFS=$'\t' read -r id declared link; do
        type=$(effective_type "$id" "$declared")
        if [[ $type == client || $type == both ]]; then
            path="$MOD_LINK_DIR/$link"
            if [[ -e $path ]]; then client_paths+=("$(relative_server_path "$path")"); fi
        fi
        if [[ $type == server || $type == both ]]; then
            path="$SERVER_MOD_LINK_DIR/$link"
            if [[ -e $path ]]; then server_paths+=("$(relative_server_path "$path")"); fi
        fi
    done < <(jq -r '.[] | [.workshop_id,.type,.link_name] | @tsv' "$MODS_FILE")
    local_mod_require_file
    local encoded source
    while IFS= read -r encoded; do
        type=$(printf '%s' "$encoded" | base64 -d | jq -r '.type')
        link=$(printf '%s' "$encoded" | base64 -d | jq -r '.link_name')
        source=$(printf '%s' "$encoded" | base64 -d | jq -r '.source_path')
        [[ -d $source ]] || die "Local mod source is missing: $link -> $source" 66
        if [[ $type == client || $type == both ]]; then
            path="$MOD_LINK_DIR/$link"
            if [[ -e $path ]]; then client_paths+=("$(relative_server_path "$path")"); fi
        fi
        if [[ $type == server || $type == both ]]; then
            path="$SERVER_MOD_LINK_DIR/$link"
            if [[ -e $path ]]; then server_paths+=("$(relative_server_path "$path")"); fi
        fi
    done < <(jq -r '.[] | @base64' "$LOCAL_MODS_FILE")
    ((${#client_paths[@]} == 0)) || generated+=("-mod=$(IFS=';'; printf '%s' "${client_paths[*]}")")
    ((${#server_paths[@]} == 0)) || generated+=("-serverMod=$(IFS=';'; printf '%s' "${server_paths[*]}")")
    temporary=$(mktemp "$RUNTIME_DIR/start-args.XXXXXX")
    {
        printf '# Generated automatically; do not edit.\n'
        declare -p generated | sed 's/^declare -a generated=/declare -a GENERATED_MOD_ARGS=/'
    } >"$temporary"
    if [[ $DRY_RUN == true ]]; then
        log DRY-RUN "Write launch arguments to $output"
        rm -f -- "$temporary"
    else
        chmod 0640 -- "$temporary"
        mv -fT -- "$temporary" "$output"
    fi
    info "Launch arguments generated: ${#generated[@]} mod argument(s)"
}

relative_server_path() {
    local path=$1 server_real path_real
    require_commands realpath
    server_real=$(realpath -ms -- "$ARMA_DIR")
    path_real=$(realpath -ms -- "$path")
    case $path_real in
        "$server_real"/*) realpath -ms --relative-to="$server_real" -- "$path_real";;
        *) die "Arma on Linux requires mod links inside $ARMA_DIR: $path" 78;;
    esac
}

build_server_args() {
    local generated_file="$RUNTIME_DIR/start-args.sh"
    GENERATED_MOD_ARGS=()
    [[ -r $generated_file ]] || generate_start_args
    # This file is generated exclusively by generate_start_args using declare -p.
    # shellcheck disable=SC1090
    source "$generated_file"
    SERVER_ARGS=("-config=$ARMA_DIR/$SERVER_CONFIG" "-cfg=$ARMA_DIR/$BASIC_CONFIG" "-port=$PORT")
    SERVER_ARGS+=("${ARMA_EXTRA_ARGS[@]}")
    SERVER_ARGS+=("${GENERATED_MOD_ARGS[@]}")
}

server_start() {
    local pid
    init_runtime
    if server_is_running; then info "Server is already running (PID $(<"$(pid_file)"))"; return 0; fi
    acquire_update_lock
    rm -f -- "$(pid_file)"
    [[ -x $ARMA_DIR/$SERVER_BINARY ]] || die "Server binary is missing: $ARMA_DIR/$SERVER_BINARY" 69
    links_rebuild
    generate_start_args
    build_server_args
    if [[ $DRY_RUN == true ]]; then
        run "$ARMA_DIR/$SERVER_BINARY" "${SERVER_ARGS[@]}"
        release_update_lock
        return
    fi
    info "Starting Arma server on port $PORT"
    (
        cd -- "$ARMA_DIR" || exit 70
        nohup "$ARMA_DIR/$SERVER_BINARY" "${SERVER_ARGS[@]}" >>"$(server_stdout_log)" 2>&1 &
        printf '%s\n' "$!" >"$(pid_file)"
    )
    read -r pid <"$(pid_file)"
    sleep 1
    if ! server_is_running; then
        rm -f -- "$(pid_file)"
        die "Server startup failed; see $(server_stdout_log)" 70
    fi
    release_update_lock
    info "Server started (PID $pid)"
}

server_run_foreground() {
    init_runtime
    acquire_update_lock
    [[ -x $ARMA_DIR/$SERVER_BINARY ]] || die "Server binary is missing" 69
    links_rebuild
    generate_start_args
    build_server_args
    printf '%s\n' "$$" >"$(pid_file)"
    release_update_lock
    cd -- "$ARMA_DIR" || die "Server directory is inaccessible: $ARMA_DIR" 73
    exec "$ARMA_DIR/$SERVER_BINARY" "${SERVER_ARGS[@]}"
}

server_stop() {
    local pid waited=0
    if ! server_is_running; then
        rm -f -- "$(pid_file)" 2>/dev/null || true
        info "Server is not running"
        return 0
    fi
    read -r pid <"$(pid_file)"
    info "Stopping server (PID $pid)"
    run kill -TERM "$pid"
    [[ $DRY_RUN == true ]] && return 0
    while kill -0 "$pid" 2>/dev/null && ((waited < STOP_TIMEOUT)); do sleep 1; ((waited += 1)); done
    if kill -0 "$pid" 2>/dev/null; then
        warn "Server did not stop after ${STOP_TIMEOUT}s; refusing to send SIGKILL without manual intervention"
        return 75
    fi
    rm -f -- "$(pid_file)"
    info "Server stopped"
}

server_restart() { server_stop && server_start; }

server_status() {
    if server_is_running; then info "Server is running (PID $(<"$(pid_file)"))"; return 0; fi
    info "Server is stopped"
    return 3
}

server_console() {
    local log_file
    log_file=$(server_stdout_log)
    [[ -e $log_file ]] || die "No console log exists yet: $log_file" 66
    exec tail -n 100 -F -- "$log_file"
}
