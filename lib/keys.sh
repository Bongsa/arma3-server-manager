#!/usr/bin/env bash

collect_mod_keys() {
    local mod_path=$1 owner=$2 keys_dir=$3 previous=$4 desired=$5 next=$6
    local -n selected_hashes=$7
    local source base stem extension hash destination candidate existing_hash owner_suffix
    owner_suffix=$(printf '%s' "$owner" | LC_ALL=C tr '[:upper:]' '[:lower:]' | \
        sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//' | cut -c1-80)
    [[ -n $owner_suffix ]] || owner_suffix=local

    while IFS= read -r -d '' source; do
        base=${source##*/}
        hash=$(sha256sum -- "$source" | awk '{print $1}')
        candidate=${base,,}
        destination="$keys_dir/$candidate"
        if [[ -n ${selected_hashes[$candidate]:-} ]]; then
            if [[ ${selected_hashes[$candidate]} == "$hash" ]]; then
                debug "Duplicate identical key: $base ($owner)"
                continue
            fi
            stem=${candidate%.*}; extension=${candidate##*.}
            candidate="${stem}-${owner_suffix}.${extension}"
            destination="$keys_dir/$candidate"
            warn "Key name collision for $base; storing the second key as $candidate"
        elif [[ -f $destination ]]; then
            existing_hash=$(sha256sum -- "$destination" | awk '{print $1}')
            if [[ $existing_hash != "$hash" ]] && ! jq -e --arg d "$candidate" \
                'any(.[]; .destination == $d)' "$previous" >/dev/null; then
                stem=${candidate%.*}; extension=${candidate##*.}
                candidate="${stem}-${owner_suffix}.${extension}"
                destination="$keys_dir/$candidate"
                warn "Existing unmanaged key $base conflicts; using $candidate"
            fi
        fi
        if [[ -n ${selected_hashes[$candidate]:-} && ${selected_hashes[$candidate]} != "$hash" ]]; then
            stem=${candidate%.*}; extension=${candidate##*.}
            candidate="${stem}-${hash:0:12}.${extension}"
            destination="$keys_dir/$candidate"
        fi
        if [[ -f $destination ]] && ! jq -e --arg d "$candidate" \
            'any(.[]; .destination == $d)' "$previous" >/dev/null; then
            existing_hash=$(sha256sum -- "$destination" | awk '{print $1}')
            if [[ $existing_hash != "$hash" ]]; then
                stem=${candidate%.*}; extension=${candidate##*.}
                candidate="${stem}-${hash:0:12}.${extension}"
                destination="$keys_dir/$candidate"
                warn "Additional key collision; using $candidate"
            fi
        fi
        selected_hashes["$candidate"]=$hash
        if [[ ! -f $destination ]] || [[ $(sha256sum -- "$destination" | awk '{print $1}') != "$hash" ]]; then
            if [[ $DRY_RUN == true ]]; then
                log DRY-RUN "install -m 0644 -- $source $destination"
            else
                atomic_install "$source" "$destination" 0644
            fi
        fi
        jq --arg destination "$candidate" --arg sha256 "$hash" --arg owner "$owner" --arg source "$source" \
            '. + [{destination:$destination,sha256:$sha256,owner:$owner,source:$source}]' \
            "$desired" >"$next"
        mv -fT -- "$next" "$desired"
    done < <(find -P "$mod_path" -type f -iname '*.bikey' -print0)
}

keys_sync() {
    local keys_dir="$ARMA_DIR/keys" manifest="$STATE_DIR/managed-keys.json"
    local previous desired next id mod_path candidate hash destination encoded owner
    # collect_mod_keys accesses this array through a name reference.
    # shellcheck disable=SC2034
    declare -A chosen_hash=()
    require_commands sha256sum find jq base64
    init_runtime
    run mkdir -p -- "$keys_dir"
    previous=$(mktemp "$STATE_DIR/keys-old.XXXXXX.json")
    desired=$(mktemp "$STATE_DIR/keys-new.XXXXXX.json")
    next=$(mktemp "$STATE_DIR/keys-next.XXXXXX.json")
    [[ -r $manifest ]] && cp -- "$manifest" "$previous" || printf '[]\n' >"$previous"
    printf '[]\n' >"$desired"

    while IFS= read -r id; do
        mod_path="$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/$id"
        [[ -d $mod_path ]] || continue
        collect_mod_keys "$mod_path" "$id" "$keys_dir" "$previous" "$desired" "$next" chosen_hash
    done < <(jq -r '.[].workshop_id' "$MODS_FILE")

    local_mod_require_file
    while IFS= read -r encoded; do
        mod_path=$(printf '%s' "$encoded" | base64 -d | jq -r '.source_path')
        owner=$(printf '%s' "$encoded" | base64 -d | jq -r '.link_name')
        [[ -d $mod_path ]] || die "Local mod source missing during key sync: $owner -> $mod_path" 66
        collect_mod_keys "$mod_path" "local_${owner#@}" "$keys_dir" "$previous" "$desired" "$next" chosen_hash
    done < <(jq -r '.[] | @base64' "$LOCAL_MODS_FILE")

    while IFS=$'\t' read -r candidate hash; do
        if ! jq -e --arg d "$candidate" 'any(.[]; .destination == $d)' "$desired" >/dev/null; then
            destination="$keys_dir/$candidate"
            if [[ -f $destination ]] && [[ $(sha256sum -- "$destination" | awk '{print $1}') == "$hash" ]]; then
                run rm -f -- "$destination"
                info "Removed obsolete managed key: $candidate"
            else
                warn "Obsolete key $candidate was modified locally and will be retained"
            fi
        fi
    done < <(jq -r '.[] | [.destination,.sha256] | @tsv' "$previous")
    [[ $DRY_RUN == true ]] || atomic_install "$desired" "$manifest" 0640
    info "Key synchronization: managing $(jq 'length' "$desired") unique keys"
    rm -f -- "$previous" "$desired" "$next"
}
