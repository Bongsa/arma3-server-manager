#!/usr/bin/env bash

lowercase_mod() {
    local id=$1
    local path="$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/$id" output
    valid_workshop_id "$id" || die "Invalid Workshop ID: $id" 64
    [[ -d $path ]] || { warn "Mod $id is not installed: $path"; return 2; }
    if [[ $DRY_RUN == true ]]; then
        if ! output=$(python3 "$PROJECT_DIR/helpers/lowercase_tree.py" --dry-run "$path"); then
            die "Lowercase preflight failed for Workshop $id" 65
        fi
    else
        if ! output=$(python3 "$PROJECT_DIR/helpers/lowercase_tree.py" "$path"); then
            die "Lowercase conversion failed for Workshop $id" 65
        fi
    fi
    info "Lowercase $id: renamed ${output##*$'\n'} entries"
}

lowercase_all() {
    local only=${1:-} id failed=0
    require_commands python3
    if [[ -n $only ]]; then
        lowercase_mod "$only"
        return
    fi
    while IFS= read -r id; do
        [[ -d $WORKSHOP_DIR/content/$WORKSHOP_APP_ID/$id ]] || continue
        lowercase_mod "$id" || failed=1
    done < <(jq -r '.[].workshop_id' "$MODS_FILE")
    ((failed == 0)) || die "At least one mod could not be converted" 65
}
