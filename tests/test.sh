#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
PRESET=${1:-$ROOT/tests/fixtures/launcher-preset.html}
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/arma3-manager-test.XXXXXX")
trap 'rm -rf -- "$TEMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

[[ -r $PRESET ]] || fail "Preset not found: $PRESET"
python3 "$ROOT/helpers/parse_preset.py" "$PRESET" "$TEMP/mods.json" \
    --workshop-content "$TEMP/workshop/content/107410" >/dev/null
jq -e 'length > 0' "$TEMP/mods.json" >/dev/null || fail "no mods detected"
jq -e 'any(.[]; .workshop_id == "450814997" and .name == "CBA_A3")' "$TEMP/mods.json" >/dev/null || fail "CBA_A3 missing"
jq -e 'any(.[]; .workshop_id == "843425103" and .name == "RHSAFRF")' "$TEMP/mods.json" >/dev/null || fail "RHSAFRF missing"
jq -e 'any(.[]; .workshop_id == "843577117" and .name == "RHSUSAF")' "$TEMP/mods.json" >/dev/null || fail "RHSUSAF missing"
[[ $(jq -r '.[].workshop_id' "$TEMP/mods.json" | sort | uniq -d | wc -l) -eq 0 ]] || fail "duplicate IDs"
pass "Launcher preset fixture ($(jq 'length' "$TEMP/mods.json") mods)"

mkdir -p "$TEMP/tree/Addons/SubDir"
touch "$TEMP/tree/Addons/SomeFile.PBO" "$TEMP/tree/Addons/SubDir/Thing.BISIGN"
ln -s '/Do/Not/Touch' "$TEMP/tree/ExternalLink"
python3 "$ROOT/helpers/lowercase_tree.py" "$TEMP/tree" >/dev/null
[[ -f $TEMP/tree/addons/somefile.pbo ]] || fail "file was not lowercased"
[[ -f $TEMP/tree/addons/subdir/thing.bisign ]] || fail "nested file was not lowercased"
[[ -L $TEMP/tree/externallink && $(readlink -- "$TEMP/tree/externallink") == /Do/Not/Touch ]] || fail "symlink handled incorrectly"
pass "lowercase conversion and symlinks"

mkdir -p "$TEMP/collision"
touch "$TEMP/collision/File.PBO" "$TEMP/collision/file.pbo"
if python3 "$ROOT/helpers/lowercase_tree.py" "$TEMP/collision" >/dev/null 2>&1; then
    fail "case collision was not detected"
fi
[[ -e $TEMP/collision/File.PBO && -e $TEMP/collision/file.pbo ]] || fail "collision modified files"
pass "case collision detected before mutation"

TX="$TEMP/transaction"
mkdir -p "$TX/workshop/content/107410/11111" "$TX/state"
printf 'known good\n' >"$TX/workshop/content/107410/11111/old.pbo"
if (
    PROJECT_DIR=$ROOT
    # shellcheck disable=SC2030
    WORKSHOP_DIR="$TX/workshop"
    # shellcheck disable=SC2030
    WORKSHOP_APP_ID=107410
    STEAMCMD_DIR="$TX/steamcmd"
    STEAMCMD_HOME="$TX/steam-home"
    STATE_DIR="$TX/state"
    DRY_RUN=false
    VERBOSE=false
    LOG_FILE=''
    # shellcheck disable=SC1090
    source "$ROOT/lib/common.sh"
    # shellcheck disable=SC1090
    source "$ROOT/lib/lowercase.sh"
    # shellcheck disable=SC1090
    source "$ROOT/lib/mods.sh"
    steamcmd_run() {
        mkdir -p "$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/11111/Addons"
        printf 'one\n' >"$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/11111/Addons/File.PBO"
        printf 'two\n' >"$WORKSHOP_DIR/content/$WORKSHOP_APP_ID/11111/Addons/file.pbo"
    }
    download_mod 11111 'Collision Test'
); then
    fail "transaction should have failed on the case collision"
fi
[[ -f $TX/workshop/content/107410/11111/old.pbo ]] || fail "mod backup was not restored"
[[ -f $TX/state/mod-11111-needs-update ]] || fail "retry marker is missing"
find "$TX/workshop/content/107410" -maxdepth 1 -type d -name '11111.failed-*' -print -quit | grep -q . || fail "failed state was not quarantined"
pass "transactional mod update with rollback"

ISO="$TEMP/steam-isolation"
mkdir -p "$ISO/steamcmd" "$ISO/steam-home/Steam/steamapps/workshop/content/107410/33333" \
    "$ISO/workshop/content/107410" "$ISO/state" "$ISO/logs"
printf 'downloaded\n' >"$ISO/steam-home/Steam/steamapps/workshop/content/107410/33333/test.pbo"
cp -- "$ROOT/tests/fixtures/fake-steamcmd.sh" "$ISO/steamcmd/steamcmd.sh"
chmod +x "$ISO/steamcmd/steamcmd.sh"
(
    PROJECT_DIR=$ROOT
    STEAMCMD_DIR="$ISO/steamcmd"
    STEAMCMD_HOME="$ISO/steam-home"
    WORKSHOP_DIR="$ISO/workshop"
    STEAM_USER=test-user
    STATE_DIR="$ISO/state"
    LOG_DIR="$ISO/logs"
    DRY_RUN=false
    VERBOSE=false
    SHOW_PROGRESS=false
    LOG_FILE=''
    STEAMCMD_AUTHENTICATED=true
    FAKE_STEAM_CAPTURE="$ISO/capture"
    export FAKE_STEAM_CAPTURE
    # shellcheck disable=SC1090
    source "$ROOT/lib/common.sh"
    # shellcheck disable=SC1090
    source "$ROOT/lib/steam.sh"
    prepare_workshop_storage
    steamcmd_run +force_install_dir "$STEAMCMD_DIR" +workshop_download_item 107410 11111 validate
)
[[ -L $ISO/steam-home/Steam/steamapps/workshop ]] || fail "isolated Workshop path was not linked"
[[ -f $ISO/workshop/content/107410/33333/test.pbo ]] || fail "isolated Workshop data was not migrated"
[[ $(sed -n '1p' "$ISO/capture") == "$ISO/steam-home" ]] || fail "SteamCMD HOME is not isolated"
[[ $(sed -n '2p' "$ISO/capture") == +force_install_dir ]] || fail "force_install_dir is not before login"
[[ $(sed -n '4p' "$ISO/capture") == +login ]] || fail "incorrect login argument order"
pass "isolated SteamCMD HOME and argument order"

BASE="$TEMP/integration"
mkdir -p "$BASE/workshop/content/107410/11111/keys" "$BASE/workshop/content/107410/22222/keys"
printf 'first key\n' >"$BASE/workshop/content/107410/11111/keys/Same.BIKEY"
printf 'second key\n' >"$BASE/workshop/content/107410/22222/keys/same.bikey"
ARMA_BASE="$BASE" RUNTIME_DIR="$TEMP/runtime" MODS_FILE="$ROOT/tests/fixtures/two-mods.json" "$ROOT/arma3-server.sh" links rebuild >/dev/null
ARMA_BASE="$BASE" RUNTIME_DIR="$TEMP/runtime" MODS_FILE="$ROOT/tests/fixtures/two-mods.json" "$ROOT/arma3-server.sh" keys sync >/dev/null
[[ -L $BASE/server/mods/@client_test ]] || fail "client link missing"
[[ -L $BASE/server/mods/@both_test && -L $BASE/server/servermods/@both_test ]] || fail "both links missing"
[[ $(find "$BASE/server/keys" -maxdepth 1 -type f -iname '*.bikey' | wc -l) -eq 2 ]] || fail "key collision was not preserved"
grep -F -- '-mod=mods/@client_test;mods/@both_test' "$TEMP/runtime/start-args.sh" >/dev/null || fail "-mod argument missing"
grep -F -- '-serverMod=servermods/@both_test' "$TEMP/runtime/start-args.sh" >/dev/null || fail "-serverMod argument missing"
pass "links, key collision, and generated arguments"

LOCAL_BASE="$TEMP/local-integration"
LOCAL_SOURCE="$TEMP/Local Mod With Spaces"
LOCAL_CONFIG="$TEMP/local-mods.json"
LOCAL_RUNTIME="$TEMP/local-runtime"
mkdir -p "$LOCAL_SOURCE/Addons" "$LOCAL_SOURCE/Keys"
printf 'local pbo\n' >"$LOCAL_SOURCE/Addons/Test.PBO"
printf 'local key\n' >"$LOCAL_SOURCE/Keys/Local.BIKEY"
printf '[]\n' >"$LOCAL_CONFIG"
ARMA_BASE="$LOCAL_BASE" RUNTIME_DIR="$LOCAL_RUNTIME" \
    MODS_FILE="$ROOT/tests/fixtures/empty-mods.json" LOCAL_MODS_FILE="$LOCAL_CONFIG" \
    "$ROOT/arma3-server.sh" local-mod add both "$LOCAL_SOURCE" >/dev/null
jq -e 'length == 1 and .[0].type == "both" and .[0].link_name == "@local_mod_with_spaces"' \
    "$LOCAL_CONFIG" >/dev/null || fail "local mod was not registered correctly"
[[ -L $LOCAL_BASE/server/mods/@local_mod_with_spaces ]] || fail "local client link missing"
[[ -L $LOCAL_BASE/server/servermods/@local_mod_with_spaces ]] || fail "local server link missing"
[[ -f $LOCAL_BASE/server/keys/local.bikey ]] || fail "local key missing"
grep -F -- '-mod=mods/@local_mod_with_spaces' "$LOCAL_RUNTIME/start-args.sh" >/dev/null || \
    fail "local -mod argument missing"
grep -F -- '-serverMod=servermods/@local_mod_with_spaces' "$LOCAL_RUNTIME/start-args.sh" >/dev/null || \
    fail "local -serverMod argument missing"

ARMA_BASE="$LOCAL_BASE" RUNTIME_DIR="$LOCAL_RUNTIME" \
    MODS_FILE="$ROOT/tests/fixtures/empty-mods.json" LOCAL_MODS_FILE="$LOCAL_CONFIG" \
    "$ROOT/arma3-server.sh" local-mod lowercase @local_mod_with_spaces >/dev/null
[[ -f $LOCAL_SOURCE/addons/test.pbo && -f $LOCAL_SOURCE/keys/local.bikey ]] || \
    fail "local mod was not lowercased"

ARMA_BASE="$LOCAL_BASE" RUNTIME_DIR="$LOCAL_RUNTIME" \
    MODS_FILE="$ROOT/tests/fixtures/empty-mods.json" LOCAL_MODS_FILE="$LOCAL_CONFIG" \
    "$ROOT/arma3-server.sh" local-mod remove @local_mod_with_spaces >/dev/null
jq -e 'length == 0' "$LOCAL_CONFIG" >/dev/null || fail "local mod remained registered"
[[ -d $LOCAL_SOURCE ]] || fail "local mod source was deleted during removal"
[[ ! -e $LOCAL_BASE/server/mods/@local_mod_with_spaces ]] || fail "local client link remained"
[[ ! -e $LOCAL_BASE/server/servermods/@local_mod_with_spaces ]] || fail "local server link remained"
[[ ! -e $LOCAL_BASE/server/keys/local.bikey ]] || fail "local key remained"
pass "local mods: add, links, keys, lowercase, launch arguments, and remove"

ARMA_BASE="$LOCAL_BASE" RUNTIME_DIR="$LOCAL_RUNTIME" \
    MODS_FILE="$ROOT/tests/fixtures/empty-mods.json" LOCAL_MODS_FILE="$LOCAL_CONFIG" \
    "$ROOT/arma3-server.sh" local-mod add client "$LOCAL_SOURCE" >/dev/null
ln -sfn -- /not/created/by/manager "$LOCAL_BASE/server/mods/@local_mod_with_spaces"
ARMA_BASE="$LOCAL_BASE" RUNTIME_DIR="$LOCAL_RUNTIME" \
    MODS_FILE="$ROOT/tests/fixtures/empty-mods.json" LOCAL_MODS_FILE="$LOCAL_CONFIG" \
    "$ROOT/arma3-server.sh" local-mod remove @local_mod_with_spaces >/dev/null
[[ -L $LOCAL_BASE/server/mods/@local_mod_with_spaces ]] || fail "manually changed link was deleted"
[[ $(readlink -- "$LOCAL_BASE/server/mods/@local_mod_with_spaces") == /not/created/by/manager ]] || \
    fail "manually changed link was overwritten"
pass "manually changed links are retained during removal"

COLLISION_SOURCE="$TEMP/Client Test"
COLLISION_CONFIG="$TEMP/local-collision.json"
mkdir -p "$COLLISION_SOURCE"
printf '[]\n' >"$COLLISION_CONFIG"
workshop_target=$(readlink -f -- "$BASE/server/mods/@client_test")
if ARMA_BASE="$BASE" RUNTIME_DIR="$TEMP/runtime" \
    MODS_FILE="$ROOT/tests/fixtures/two-mods.json" LOCAL_MODS_FILE="$COLLISION_CONFIG" \
    "$ROOT/arma3-server.sh" local-mod add client "$COLLISION_SOURCE" >/dev/null 2>&1; then
    fail "collision between local mod and Workshop link was not detected"
fi
jq -e 'length == 0' "$COLLISION_CONFIG" >/dev/null || fail "collision modified the local registry"
[[ $(readlink -f -- "$BASE/server/mods/@client_test") == "$workshop_target" ]] || \
    fail "collision modified the Workshop link"
pass "local link names cannot silently collide with Workshop mods"

bash -n "$ROOT/arma3-server.sh" "$ROOT"/lib/*.sh
pass "Bash syntax"
