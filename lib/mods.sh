#!/usr/bin/env bash

workshop_manifest() { printf '%s/appworkshop_%s.acf\n' "$WORKSHOP_DIR" "$WORKSHOP_APP_ID"; }

mods_list() {
    local id name declared effective classification
    require_commands jq
    printf '%-12s | %-42s | %-7s | %s\n' 'Workshop ID' 'Name' 'Type' 'Classification'
    printf '%s\n' '-------------+--------------------------------------------+---------+--------------------------'
    while IFS=$'\t' read -r id name declared classification; do
        effective=$(effective_type "$id" "$declared")
        [[ $effective == "$declared" ]] || classification=manual-override
        printf '%-12s | %-42.42s | %-7s | %s\n' "$id" "$name" "$effective" "$classification"
    done < <(jq -r '.[] | [.workshop_id,.name,.type,.classification] | @tsv' "$MODS_FILE")
}

fetch_remote_metadata() {
    local destination=$1 count=0 id temp
    local curl_args=(--fail --silent --show-error --max-time 30 -X POST)
    while IFS= read -r id; do
        curl_args+=(--data-urlencode "publishedfileids[$count]=$id")
        ((count += 1))
    done < <(jq -r '.[].workshop_id' "$MODS_FILE")
    curl_args+=(--data-urlencode "itemcount=$count")
    if ((count == 0)); then printf '{}\n' >"$destination"; return 0; fi
    temp=$(mktemp "$STATE_DIR/remote.XXXXXX.json")
    if ! curl "${curl_args[@]}" \
        'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/' >"$temp"; then
        warn "Steam Workshop metadata is unavailable; update status is unknown"
        printf '{}\n' >"$destination"
        rm -f -- "$temp"
        return 0
    fi
    if ! jq -e '.response.publishedfiledetails | type == "array"' "$temp" >/dev/null 2>&1; then
        warn "Unexpected Steam Workshop metadata; update status is unknown"
        printf '{}\n' >"$destination"
    else
        jq '.response.publishedfiledetails | map({key:.publishedfileid,value:{time_updated:(.time_updated|tonumber),result:(.result|tonumber),title:.title}}) | from_entries' \
            "$temp" >"$destination"
    fi
    rm -f -- "$temp"
}

compute_mod_status() {
    local destination=$1 local_data remote_data manifest
    init_runtime
    local_data=$(mktemp "$STATE_DIR/local.XXXXXX.json")
    remote_data=$(mktemp "$STATE_DIR/remote.XXXXXX.json")
    manifest=$(workshop_manifest)
    python3 "$PROJECT_DIR/helpers/read_workshop_manifest.py" "$manifest" >"$local_data" || printf '{}\n' >"$local_data"
    fetch_remote_metadata "$remote_data"
    jq -n --slurpfile mods "$MODS_FILE" --slurpfile local "$local_data" --slurpfile remote "$remote_data" \
        --arg root "$WORKSHOP_DIR/content/$WORKSHOP_APP_ID" '
        [$mods[0][] | . as $m | ($m.workshop_id) as $id |
          ($local[0][$id].time_updated // 0) as $lt |
          ($remote[0][$id].time_updated // 0) as $rt |
          . + {installed: (($local[0][$id] != null) and (($root + "/" + $id) | length > 0)),
               local_time:$lt, remote_time:$rt,
               remote_result:($remote[0][$id].result // 0),
               update_status:(if $remote[0][$id].result == 9 then "removed"
                              elif $local[0][$id] == null then "missing"
                              elif $rt == 0 or $lt == 0 then "unknown"
                              elif $rt > $lt then "yes" else "no" end)}]' \
        >"$destination"
    # The manifest alone is insufficient if a directory vanished.
    local id exists tmp
    tmp=$(mktemp "$STATE_DIR/status.XXXXXX.json")
    cp -- "$destination" "$tmp"
    while IFS= read -r id; do
        exists=false
        [[ -d $WORKSHOP_DIR/content/$WORKSHOP_APP_ID/$id ]] && exists=true
        jq --arg id "$id" --argjson exists "$exists" \
            'map(if .workshop_id == $id then .installed=$exists |
                if $exists or .update_status == "removed" then . else .update_status="missing" end
                else . end)' \
            "$tmp" >"$destination"
        cp -- "$destination" "$tmp"
        if [[ -e $STATE_DIR/mod-$id-needs-update ]]; then
            jq --arg id "$id" 'map(if .workshop_id == $id and .update_status != "removed" then .update_status="yes" else . end)' \
                "$tmp" >"$destination"
            cp -- "$destination" "$tmp"
        fi
    done < <(jq -r '.[].workshop_id' "$MODS_FILE")
    rm -f -- "$local_data" "$remote_data" "$tmp"
}

restore_mod_download_backup() {
    local failed_path
    [[ -n ${MOD_DOWNLOAD_BACKUP:-} && -n ${MOD_DOWNLOAD_TARGET:-} ]] || return 0
    [[ -d $MOD_DOWNLOAD_BACKUP ]] || return 0
    if [[ -e $MOD_DOWNLOAD_TARGET ]]; then
        failed_path="${MOD_DOWNLOAD_TARGET}.failed-$(date +%Y%m%d-%H%M%S)"
        mv -- "$MOD_DOWNLOAD_TARGET" "$failed_path" 2>/dev/null || true
        warn "Retained failed new mod state for diagnostics: $failed_path"
    fi
    mv -- "$MOD_DOWNLOAD_BACKUP" "$MOD_DOWNLOAD_TARGET" 2>/dev/null || true
    : >"$STATE_DIR/mod-${MOD_DOWNLOAD_ID}-needs-update"
    warn "Restored the previous state of Workshop item $MOD_DOWNLOAD_ID"
}

mods_check() {
    local status id name installed update declared type
    require_commands jq curl python3
    status=$(mktemp "${TMPDIR:-/tmp}/arma3-status.XXXXXX.json")
    trap 'rm -f -- "$status"' RETURN
    compute_mod_status "$status"
    printf '%-12s | %-36s | %-9s | %-16s | %s\n' 'Workshop ID' 'Name' 'Installed' 'Update available' 'Type'
    printf '%s\n' '-------------+--------------------------------------+-----------+------------------+--------'
    while IFS=$'\t' read -r id name installed update declared; do
        type=$(effective_type "$id" "$declared")
        printf '%-12s | %-36.36s | %-9s | %-16s | %s\n' "$id" "$name" "$installed" "$update" "$type"
    done < <(jq -r '.[] | [.workshop_id,.name,.installed,.update_status,.type] | @tsv' "$status")
    trap - RETURN
    rm -f -- "$status"
}

download_mod() {
    local id=$1 name=$2
    local path="$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/$id"
    local backup="$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/.arma3-manager-${id}-backup-$$"
    local batch=''
    if ((${DOWNLOAD_BATCH_TOTAL:-0} > 0)); then
        batch="[${DOWNLOAD_BATCH_INDEX}/${DOWNLOAD_BATCH_TOTAL}] "
    fi
    info "[STEAM] ${batch}Downloading and validating Workshop $id ($name)"
    [[ $DRY_RUN == true ]] || : >"$STATE_DIR/mod-$id-needs-update"
    if [[ $DRY_RUN != true && -d $path ]]; then
        [[ ! -e $backup ]] || die "Unexpected backup already exists: $backup" 73
        mv -- "$path" "$backup"
        MOD_DOWNLOAD_BACKUP=$backup MOD_DOWNLOAD_TARGET=$path MOD_DOWNLOAD_ID=$id
        trap restore_mod_download_backup EXIT
    fi
    # Read by steamcmd_run from lib/steam.sh.
    # shellcheck disable=SC2034
    STEAM_CONTEXT="Workshop ID=$id mod name=$name"
    steamcmd_run +workshop_download_item "$WORKSHOP_APP_ID" "$id" validate
    unset STEAM_CONTEXT
    if [[ $DRY_RUN != true && ! -d $path ]]; then
        die "Workshop download failed: ID=$id name=$name path=$path log=$LOG_FILE" 70
    fi
    [[ $DRY_RUN == true ]] || lowercase_mod "$id"
    if [[ $DRY_RUN != true && -d $backup ]]; then
        case $backup in
            "$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/.arma3-manager-${id}-backup-"*) rm -rf -- "$backup";;
            *) die "Unsafe internal backup path: $backup" 70;;
        esac
    fi
    rm -f -- "$STATE_DIR/mod-$id-needs-update"
    MOD_DOWNLOAD_BACKUP='' MOD_DOWNLOAD_TARGET='' MOD_DOWNLOAD_ID=''
    trap - EXIT
}

mods_update() {
    local only=${1:-} status id name update failed=0 changed=0 was_running=false
    local download_total=0 download_index=0
    [[ -z $only ]] || valid_workshop_id "$only" || die "Invalid Workshop ID: $only" 64
    if [[ -n $only ]] && ! jq -e --arg id "$only" 'any(.[]; .workshop_id == $id)' "$MODS_FILE" >/dev/null; then
        die "Workshop ID $only is not present in config/mods.json" 66
    fi
    init_runtime
    init_layout
    acquire_update_lock
    check_free_space "$WORKSHOP_DIR"
    install_steamcmd
    if server_is_running; then
        was_running=true
        if [[ $DEFER_IF_RUNNING == true ]]; then warn "Server is running; mod update deferred"; release_update_lock; return 0; fi
        [[ $FORCE == true ]] || die "Server is running; mod updates require downtime (or --force)" 75
        server_stop
    fi
    status=$(mktemp "$STATE_DIR/status.XXXXXX.json")
    compute_mod_status "$status"
    download_total=$(jq --arg only "$only" --arg force "$FORCE" '
        [.[] | select(($only == "" or .workshop_id == $only) and
         (.update_status == "missing" or .update_status == "yes" or
          (.update_status == "unknown" and $force == "true")))] | length' "$status")
    DOWNLOAD_BATCH_TOTAL=$download_total
    while IFS=$'\t' read -r id name update; do
        [[ -z $only || $id == "$only" ]] || continue
        case $update in
            missing|yes)
                ((download_index += 1)); DOWNLOAD_BATCH_INDEX=$download_index
                download_mod "$id" "$name" || failed=1; ((changed += 1));;
            unknown)
                if [[ $FORCE == true ]]; then
                    ((download_index += 1)); DOWNLOAD_BATCH_INDEX=$download_index
                    download_mod "$id" "$name" || failed=1; ((changed += 1))
                else warn "$id ($name): status unknown; not downloaded without --force"
                fi;;
            removed) warn "$id ($name) was removed from the Workshop";;
            no) debug "$id ($name) is current";;
        esac
    done < <(jq -r '.[] | [.workshop_id,.name,.update_status] | @tsv' "$status")
    unset DOWNLOAD_BATCH_TOTAL DOWNLOAD_BATCH_INDEX
    rm -f -- "$status"
    links_rebuild
    keys_sync
    generate_start_args
    info "Mod update complete: $changed download(s), failures=$failed"
    release_update_lock
    if [[ $was_running == true && $AUTO_RESTART == true ]]; then server_start
    elif [[ $was_running == true ]]; then warn "Server remains stopped because AUTO_RESTART=false"; fi
    ((failed == 0)) || return 70
}

full_install() {
    init_runtime
    acquire_update_lock
    server_install
    mods_update ""
    release_update_lock
}

full_update() {
    local was_running=false
    init_runtime
    acquire_update_lock
    if server_is_running; then
        was_running=true
        if [[ $DEFER_IF_RUNNING == true ]]; then warn "Server is running; full update deferred"; release_update_lock; return 0; fi
        [[ $FORCE == true ]] || die "Server is running; a full update requires downtime or --force" 75
        server_stop
    fi
    # Subfunctions do not acquire the same lock recursively, so run the sequence directly.
    init_layout
    check_free_space "$ARMA_DIR"
    install_steamcmd
    steamcmd_run +force_install_dir "$ARMA_DIR" +app_update "$ARMA_APP_ID" validate
    install_server_config_templates
    local status id name update changed=0 download_total=0 download_index=0
    status=$(mktemp "$STATE_DIR/status.XXXXXX.json")
    compute_mod_status "$status"
    download_total=$(jq '[.[] | select(.update_status == "missing" or .update_status == "yes")] | length' "$status")
    DOWNLOAD_BATCH_TOTAL=$download_total
    while IFS=$'\t' read -r id name update; do
        case $update in
            missing|yes)
                ((download_index += 1)); DOWNLOAD_BATCH_INDEX=$download_index
                download_mod "$id" "$name"; ((changed += 1));;
            unknown) warn "$id ($name): status unknown, skipped";;
            removed) warn "$id ($name): Workshop item removed";;
        esac
    done < <(jq -r '.[] | [.workshop_id,.name,.update_status] | @tsv' "$status")
    unset DOWNLOAD_BATCH_TOTAL DOWNLOAD_BATCH_INDEX
    rm -f -- "$status"
    links_rebuild
    keys_sync
    generate_start_args
    info "Full update successful: server validated, $changed mod download(s)"
    release_update_lock
    if [[ $was_running == true && $AUTO_RESTART == true ]]; then server_start
    elif [[ $was_running == true ]]; then warn "Server remains stopped because AUTO_RESTART=false"; fi
}
