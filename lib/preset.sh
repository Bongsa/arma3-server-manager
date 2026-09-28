#!/usr/bin/env bash

import_preset() {
    local preset=$1 count
    [[ -r $preset ]] || die "Preset is not readable: $preset" 66
    require_commands python3 jq
    count=$(python3 "$PROJECT_DIR/helpers/parse_preset.py" "$preset" "$MODS_FILE" \
        --workshop-content "$WORKSHOP_DIR/content/$WORKSHOP_APP_ID") || die "Preset import failed" 65
    jq -e 'type == "array" and all(.[]; (.workshop_id | test("^[1-9][0-9]+$")) and (.name | length > 0))' \
        "$MODS_FILE" >/dev/null || die "Parser produced an invalid mod list" 65
    info "Atomically imported $count Workshop mods into $MODS_FILE"
    mods_list
}
