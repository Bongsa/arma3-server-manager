#!/usr/bin/env bash

local_mod_require_file() {
    require_commands jq realpath base64 sha256sum sed cut tr
    if [[ ! -r $LOCAL_MODS_FILE ]]; then
        mkdir -p -- "$(dirname -- "$LOCAL_MODS_FILE")"
        printf '[]\n' >"$LOCAL_MODS_FILE"
        chmod 0640 -- "$LOCAL_MODS_FILE"
    fi
    jq -e 'type == "array" and all(.[];
        (.name|type=="string" and length > 0) and
        (.source_path|type=="string" and startswith("/")) and
        (.link_name|test("^@[a-z0-9][a-z0-9_-]*$")) and
        (.type == "client" or .type == "server" or .type == "both")) and
        (([.[].source_path] | length) == ([.[].source_path] | unique | length)) and
        (([.[].link_name] | length) == ([.[].link_name] | unique | length))' \
        "$LOCAL_MODS_FILE" >/dev/null || die "Invalid local mod list: $LOCAL_MODS_FILE" 78
}

local_mod_type_valid() { [[ $1 == client || $1 == server || $1 == both ]]; }

local_mod_types_overlap() {
    local first=$1 second=$2
    [[ $first == both || $second == both || $first == "$second" ]]
}

local_mod_slug() {
    local source=$1 raw slug hash
    raw=$(basename -- "$source")
    raw=${raw#@}
    slug=$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_' | \
        sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//' | cut -c1-180)
    if [[ -z $slug ]]; then
        hash=$(printf '%s' "$source" | sha256sum | awk '{print $1}')
        slug="local_${hash:0:12}"
    fi
    printf '@%s\n' "$slug"
}

local_mod_assert_workshop_link_available() {
    local link=$1 type=$2 encoded workshop_id workshop_type workshop_link
    while IFS= read -r encoded; do
        workshop_id=$(printf '%s' "$encoded" | base64 -d | jq -r '.workshop_id')
        workshop_type=$(effective_type "$workshop_id" "$(printf '%s' "$encoded" | base64 -d | jq -r '.type')")
        workshop_link=$(printf '%s' "$encoded" | base64 -d | jq -r '.link_name')
        if [[ $workshop_link == "$link" ]] && local_mod_types_overlap "$type" "$workshop_type"; then
            die "Local link name $link conflicts with Workshop ID $workshop_id ($workshop_type)" 78
        fi
    done < <(jq -r '.[] | @base64' "$MODS_FILE")
}

local_mod_validate_workshop_collisions() {
    local encoded type link
    local_mod_require_file
    while IFS= read -r encoded; do
        type=$(printf '%s' "$encoded" | base64 -d | jq -r '.type')
        link=$(printf '%s' "$encoded" | base64 -d | jq -r '.link_name')
        local_mod_assert_workshop_link_available "$link" "$type"
    done < <(jq -r '.[] | @base64' "$LOCAL_MODS_FILE")
}

local_mod_assert_source_safe() {
    local source=$1 client_root server_root
    client_root=$(realpath -m -- "$MOD_LINK_DIR")
    server_root=$(realpath -m -- "$SERVER_MOD_LINK_DIR")
    case $source in
        "$client_root"|"$client_root"/*|"$server_root"|"$server_root"/*)
            die "A local mod source cannot be inside a managed link directory: $source" 78;;
    esac
}

local_mod_link_points_to() {
    local destination=$1 target=$2 raw
    [[ -L $destination ]] || return 1
    raw=$(readlink -- "$destination")
    [[ $raw == "$target" ]] && return 0
    # Compare canonical paths only while both targets can still be resolved. This
    # prevents accidental removal of a manually changed link that is now broken.
    [[ -e $destination && -e $target ]] || return 1
    [[ $(readlink -f -- "$destination") == $(realpath -e -- "$target") ]]
}

local_mod_add() {
    local type=$1 input=$2 source name link count existing_link temporary
    local_mod_type_valid "$type" || die "Local mod type must be client, server, or both: $type" 64
    local_mod_require_file
    if [[ $DRY_RUN != true ]]; then
        init_runtime
        acquire_update_lock
    fi
    [[ -d $input ]] || die "Local mod directory not found: $input" 66
    source=$(realpath -e -- "$input")
    local_mod_assert_source_safe "$source"
    name=$(basename -- "$source")
    count=$(jq --arg source "$source" '[.[] | select(.source_path == $source)] | length' "$LOCAL_MODS_FILE")
    if ((count > 0)); then
        link=$(jq -r --arg source "$source" '.[] | select(.source_path == $source) | .link_name' "$LOCAL_MODS_FILE" | head -n1)
        info "Local mod is already registered; changing its type to $type: $link"
    else
        link=$(local_mod_slug "$source")
    fi
    local_mod_assert_workshop_link_available "$link" "$type"
    existing_link=$(jq --arg link "$link" --arg source "$source" \
        '[.[] | select(.link_name == $link and .source_path != $source)] | length' "$LOCAL_MODS_FILE")
    ((existing_link == 0)) || die "Local link name is already in use: $link" 78
    if [[ $DRY_RUN == true ]]; then
        log DRY-RUN "Register local mod: $link ($type) -> $source"
        return 0
    fi
    temporary=$(mktemp "$(dirname -- "$LOCAL_MODS_FILE")/local-mods.XXXXXX.json")
    jq --arg source "$source" --arg name "$name" --arg link "$link" --arg type "$type" '
        if any(.[]; .source_path == $source) then
            map(if .source_path == $source then .name=$name | .link_name=$link | .type=$type else . end)
        else . + [{name:$name,source_path:$source,link_name:$link,type:$type}] end' \
        "$LOCAL_MODS_FILE" >"$temporary"
    atomic_install "$temporary" "$LOCAL_MODS_FILE" 0640
    rm -f -- "$temporary"
    info "Registered local mod: $link ($type) -> $source"
    local_mod_sync_all
    release_update_lock
}

local_mod_list() {
    local encoded name type link source installed
    local_mod_require_file
    printf '%-24s | %-7s | %-9s | %s\n' 'Name' 'Type' 'Available' 'Source'
    printf '%s\n' '-------------------------+---------+-----------+----------------------------------------'
    while IFS= read -r encoded; do
        name=$(printf '%s' "$encoded" | base64 -d | jq -r '.name')
        type=$(printf '%s' "$encoded" | base64 -d | jq -r '.type')
        link=$(printf '%s' "$encoded" | base64 -d | jq -r '.link_name')
        source=$(printf '%s' "$encoded" | base64 -d | jq -r '.source_path')
        installed=no; [[ -d $source ]] && installed=yes
        printf '%-24.24s | %-7s | %-9s | %s (%s)\n' "$link" "$type" "$installed" "$source" "$name"
    done < <(jq -r '.[] | @base64' "$LOCAL_MODS_FILE")
}

local_mod_select() {
    local selector=$1 count
    count=$(jq --arg selector "$selector" '[.[] | select(
        .link_name == $selector or .name == $selector or .source_path == $selector)] | length' "$LOCAL_MODS_FILE")
    ((count == 1)) || {
        ((count == 0)) && die "Local mod not found: $selector" 66
        die "Local mod selector is ambiguous: $selector" 78
    }
    jq -c --arg selector "$selector" '.[] | select(
        .link_name == $selector or .name == $selector or .source_path == $selector)' "$LOCAL_MODS_FILE"
}

local_mod_remove() {
    local selector=$1 selected source link temporary
    local_mod_require_file
    if [[ $DRY_RUN != true ]]; then
        init_runtime
        acquire_update_lock
    fi
    selected=$(local_mod_select "$selector")
    source=$(jq -r '.source_path' <<<"$selected")
    link=$(jq -r '.link_name' <<<"$selected")
    if [[ $DRY_RUN == true ]]; then
        log DRY-RUN "Remove local mod from management: $link (source retained: $source)"
        return 0
    fi
    temporary=$(mktemp "$(dirname -- "$LOCAL_MODS_FILE")/local-mods.XXXXXX.json")
    jq --arg source "$source" 'map(select(.source_path != $source))' "$LOCAL_MODS_FILE" >"$temporary"
    atomic_install "$temporary" "$LOCAL_MODS_FILE" 0640
    rm -f -- "$temporary"
    info "Removed local mod: $link; source data remains unchanged at $source"
    local_mod_sync_all
    release_update_lock
}

local_mod_ensure_link() {
    local destination=$1 target=$2 previous=$3 was_managed=false
    jq -e --arg destination "$destination" 'any(.[]; .destination == $destination)' "$previous" >/dev/null && was_managed=true
    if [[ -L $destination ]]; then
        if local_mod_link_points_to "$destination" "$target"; then
            printf '%s\n' "$was_managed"
            return 0
        fi
        if [[ $was_managed == true ]]; then
            run ln -sfn -- "$target" "$destination"
            printf 'true\n'
            return 0
        fi
        die "An unmanaged symlink blocks the local mod: $destination" 73
    fi
    if [[ -e $destination ]]; then
        if [[ -d $destination && $(realpath -e -- "$destination") == "$target" ]]; then
            printf 'false\n'
            return 0
        fi
        die "Local mod destination is already occupied: $destination" 73
    fi
    run ln -s -- "$target" "$destination"
    printf 'true\n'
}

local_mod_sync_links() {
    local manifest="$STATE_DIR/managed-local-links.json" previous desired next encoded type link source destination managed
    local_mod_require_file
    init_runtime
    run mkdir -p -- "$MOD_LINK_DIR" "$SERVER_MOD_LINK_DIR"
    previous=$(mktemp "$STATE_DIR/local-links-old.XXXXXX.json")
    desired=$(mktemp "$STATE_DIR/local-links-new.XXXXXX.json")
    next=$(mktemp "$STATE_DIR/local-links-next.XXXXXX.json")
    [[ -r $manifest ]] && cp -- "$manifest" "$previous" || printf '[]\n' >"$previous"
    printf '[]\n' >"$desired"
    while IFS= read -r encoded; do
        type=$(printf '%s' "$encoded" | base64 -d | jq -r '.type')
        link=$(printf '%s' "$encoded" | base64 -d | jq -r '.link_name')
        source=$(printf '%s' "$encoded" | base64 -d | jq -r '.source_path')
        [[ -d $source ]] || die "Local mod source is missing: $link -> $source" 66
        source=$(realpath -e -- "$source")
        local_mod_assert_source_safe "$source"
        local_mod_assert_workshop_link_available "$link" "$type"
        if [[ $type == client || $type == both ]]; then
            destination="$MOD_LINK_DIR/$link"
            managed=$(local_mod_ensure_link "$destination" "$source" "$previous")
            if [[ $managed == true ]]; then
                jq --arg destination "$destination" --arg target "$source" \
                    '. + [{destination:$destination,target:$target}]' "$desired" >"$next"
                mv -fT -- "$next" "$desired"
            fi
        fi
        if [[ $type == server || $type == both ]]; then
            destination="$SERVER_MOD_LINK_DIR/$link"
            managed=$(local_mod_ensure_link "$destination" "$source" "$previous")
            if [[ $managed == true ]]; then
                jq --arg destination "$destination" --arg target "$source" \
                    '. + [{destination:$destination,target:$target}]' "$desired" >"$next"
                mv -fT -- "$next" "$desired"
            fi
        fi
    done < <(jq -r '.[] | @base64' "$LOCAL_MODS_FILE")
    while IFS= read -r encoded; do
        destination=$(printf '%s' "$encoded" | base64 -d | jq -r '.destination')
        source=$(printf '%s' "$encoded" | base64 -d | jq -r '.target')
        if ! jq -e --arg destination "$destination" 'any(.[]; .destination == $destination)' "$desired" >/dev/null; then
            if local_mod_link_points_to "$destination" "$source"; then
                run rm -- "$destination"
            else
                warn "Formerly managed local link was modified and will be retained: $destination"
            fi
        fi
    done < <(jq -r '.[] | @base64' "$previous")
    [[ $DRY_RUN == true ]] || atomic_install "$desired" "$manifest" 0640
    info "Local mod links synchronized: managing $(jq 'length' "$desired") links"
    rm -f -- "$previous" "$desired" "$next"
}

local_mod_sync_all() {
    init_runtime
    init_layout
    acquire_update_lock
    links_rebuild
    keys_sync
    generate_start_args
    release_update_lock
}

local_mod_lowercase() {
    local selector=$1 selected source output
    local_mod_require_file
    selected=$(local_mod_select "$selector")
    source=$(jq -r '.source_path' <<<"$selected")
    [[ -d $source ]] || die "Local mod source is missing: $source" 66
    source=$(realpath -e -- "$source")
    local_mod_assert_source_safe "$source"
    init_runtime
    acquire_update_lock
    server_is_running && die "Server is running; the local mod source will not be modified" 75
    warn "Lowercase modifies the local mod source directly: $source"
    if [[ $DRY_RUN == true ]]; then
        output=$(python3 "$PROJECT_DIR/helpers/lowercase_tree.py" --dry-run "$source") || \
            die "Lowercase preflight failed: $source" 65
    else
        output=$(python3 "$PROJECT_DIR/helpers/lowercase_tree.py" "$source") || \
            die "Lowercase conversion failed: $source" 65
    fi
    info "Local mod lowercased: renamed ${output##*$'\n'} entries"
    keys_sync
    release_update_lock
}
