#!/bin/zsh
set -euo pipefail
setopt null_glob
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SOURCE_APP="/Applications/Codex.app"
TARGET_APP="/Applications/Codex-HistoryPatch.app"
LIMIT="350"
BUNDLE_ID="local.codex.historypatch"
APP_NAME="Codex-HistoryPatch"
WORK_DIR="${TMPDIR:-/tmp}/codex-historypatcher"
LAUNCH_AFTER="1"
KEEP_WORK="0"
REPAIR_MACOS_XATTRS="0"
RESET_REMOVABLE_VOLUMES_TCC="0"

usage() {
  cat <<'EOF'
Usage:
  repatch-codex-history.sh [options]

Options:
  --source PATH      Source Codex.app. Default: /Applications/Codex.app
  --target PATH      Patched output app. Default: /Applications/Codex-HistoryPatch.app
  --limit N          Recent thread fetch limit. Default: 350
  --bundle-id ID     Bundle id for patched app. Default: local.codex.historypatch
  --app-name NAME    Display name for patched app. Default: Codex-HistoryPatch
  --work-dir PATH    Temporary working directory. Default: $TMPDIR/codex-historypatcher
  --no-launch        Do not launch the patched app after installation
  --keep-work        Keep extracted temporary files for inspection
  --repair-macos-xattrs
                    Remove provenance/quarantine xattrs from the copied target app
  --reset-removable-volumes-tcc
                    Reset Removable Volumes permission for the patched bundle id
  -h, --help         Show this help

This script copies the installed Codex app, patches local history/thread-list
limits in app.asar, gives the copy a separate bundle id, ad-hoc signs it, and
installs it as the target app.
EOF
}

log() {
  printf '[codex-historypatcher] %s\n' "$*"
}

fail() {
  printf '[codex-historypatcher] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

target_abs_path() {
  local input_path="$1"
  local dir
  local base
  dir="$(dirname "$input_path")"
  base="$(basename "$input_path")"
  mkdir -p "$dir"
  printf '%s/%s\n' "$(cd "$dir" && pwd -P)" "$base"
}

existing_abs_path() {
  local input_path="$1"
  [[ -d "$input_path" ]] || fail "Directory does not exist: $input_path"
  (cd "$input_path" && pwd -P)
}

plist_set_or_add_string() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null ||
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" >/dev/null
}

stop_processes_for_path() {
  local app_path="$1"
  local pids=()
  local line
  local pid
  local cmd

  while IFS= read -r line; do
    pid="${line%% *}"
    cmd="${line#* }"
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    [[ "$cmd" == *"$app_path"* ]] && pids+=("$pid")
  done < <(ps -axo pid=,command=)

  if (( ${#pids[@]} == 0 )); then
    return
  fi

  log "Stopping running target processes: ${pids[*]}"
  kill -TERM "${pids[@]}" 2>/dev/null || true
  sleep 2

  local survivors=()
  for pid in "${pids[@]}"; do
    kill -0 "$pid" 2>/dev/null && survivors+=("$pid")
  done

  if (( ${#survivors[@]} > 0 )); then
    log "Force-stopping remaining target processes: ${survivors[*]}"
    kill -KILL "${survivors[@]}" 2>/dev/null || true
    sleep 1
  fi
}

running_under_target_app() {
  local app_path="$1"
  local pid
  local cmd

  pid="$(ps -p "$$" -o ppid= | tr -d ' ')"
  while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ "$cmd" == *"$app_path"* ]] && return 0
    pid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')"
  done
  return 1
}

repair_macos_xattrs() {
  local app="$1"

  command -v xattr >/dev/null 2>&1 || {
    log "xattr not found; skipping macOS xattr repair"
    return
  }

  log "Removing macOS provenance/quarantine xattrs from copied app"
  xattr -dr com.apple.provenance "$app" 2>/dev/null || true
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
}

reset_removable_volumes_tcc() {
  local bundle_id="$1"

  command -v tccutil >/dev/null 2>&1 || {
    log "tccutil not found; skipping Removable Volumes permission reset"
    return
  }

  log "Resetting Removable Volumes permission for $bundle_id"
  tccutil reset SystemPolicyRemovableVolumes "$bundle_id" 2>/dev/null ||
    log "Could not reset Removable Volumes permission; reset it manually if dialogs continue"
}

add_removable_volumes_usage_descriptions() {
  local app="$1"
  local app_name="$2"
  local usage="$app_name needs access to project files on removable volumes when you open projects stored on external drives."
  local plist
  local count=0

  while IFS= read -r -d '' plist; do
    plist_set_or_add_string "$plist" "NSRemovableVolumesUsageDescription" "$usage"
    count=$((count + 1))
  done < <(find "$app/Contents" -type f -name Info.plist -print0)

  log "Added Removable Volumes usage descriptions to $count Info.plist files"
}

patch_history_limits() {
  local extracted="$1"
  local limit="$2"
  local server_file=""
  local sidebar_file=""
  local file

  for file in "$extracted"/webview/assets/app-server-manager-signals-*.js; do
    if rg -q 'nextRecentConversationCursor' "$file" &&
       rg -q 'recentConversationPageCount' "$file"; then
      server_file="$file"
      break
    fi
  done
  [[ -n "$server_file" ]] || fail "Could not find recent conversation loader bundle"

  perl -0pi -e "s/limit:[0-9]+,cursor:this\\.nextRecentConversationCursor/limit:${limit},cursor:this.nextRecentConversationCursor/g; s/limit:[0-9]+\\*this\\.recentConversationPageCount,cursor:null/limit:${limit}*this.recentConversationPageCount,cursor:null/g" "$server_file"

  rg -q "limit:${limit},cursor:this\\.nextRecentConversationCursor" "$server_file" ||
    fail "Incremental recent conversation limit was not patched"
  rg -q "limit:${limit}\\*this\\.recentConversationPageCount,cursor:null" "$server_file" ||
    fail "Recent conversation refresh limit was not patched"

  node - "$server_file" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
const source = fs.readFileSync(file, "utf8");
const alreadyPatched =
  /async listRecentThreads\(\{cursor:[A-Za-z_$][\w$]*,limit:[A-Za-z_$][\w$]*\}\)\{let n=\[\],r=/.test(source) &&
  source.includes("Math.max(0,l-n.length)");

if (alreadyPatched) {
  process.exit(0);
}

const recentListPattern =
  /listRecentThreads\(\{cursor:([A-Za-z_$][\w$]*),limit:([A-Za-z_$][\w$]*)\}\)\{return this\.params\.requestClient\.sendRequest\(`thread\/list`,\{limit:\2,cursor:\1,sortKey:this\.recentConversationSortKey,(?:modelProviders:null,)?archived:!1,sourceKinds:([A-Za-z_$][\w$]*)\}\)\}/;

if (!recentListPattern.test(source)) {
  console.error("Could not patch listRecentThreads pagination helper");
  process.exit(1);
}

const patched = source.replace(recentListPattern, (_match, cursorVar, limitVar, sourceKindsVar) =>
  `async listRecentThreads({cursor:${cursorVar},limit:${limitVar}}){let n=[],r=${cursorVar},i=null,a=null,o=0,l=${limitVar}??100;for(;;){let s=await this.params.requestClient.sendRequest(\`thread/list\`,{limit:Math.max(0,l-n.length),cursor:r,sortKey:this.recentConversationSortKey,modelProviders:null,archived:!1,sourceKinds:${sourceKindsVar}});a??=s.backwardsCursor??null,i=s.nextCursor??null;for(let e of s.data)n.push(e);if(i==null||i===r||s.data.length===0||n.length>=l||++o>=20)break;r=i}return{data:n,nextCursor:i,backwardsCursor:a}}`
);

fs.writeFileSync(file, patched);
NODE

  rg -q "Math.max\\(0,l-n\\.length\\)" "$server_file" ||
    fail "Recent conversation pagination helper was not patched"
  node --check "$server_file" >/dev/null
  log "Patched recent thread loader: ${server_file#$extracted/}"

  for file in "$extracted"/webview/assets/sidebar-thread-list-signals-*.js; do
    if rg -q '`inbox-items`' "$file"; then
      sidebar_file="$file"
      break
    fi
  done

  if [[ -n "$sidebar_file" ]]; then
    perl -0pi -e 's/(`inbox-items`,\{params:\{limit:)[0-9]+/${1}'"$limit"'/g' "$sidebar_file"
    rg -q "params:\\{limit:${limit}\\}" "$sidebar_file" ||
      fail "Sidebar inbox-items limit was not patched"
    node --check "$sidebar_file" >/dev/null
    log "Patched sidebar inbox limit: ${sidebar_file#$extracted/}"
  else
    log "No sidebar-thread-list bundle found; skipping optional inbox-items patch"
  fi
}

patch_removable_volume_probes() {
  local extracted="$1"
  local sidebar_project_file=""
  local server_file=""
  local sidebar_thread_file=""
  local background_terminals_file=""
  local file

  for file in "$extracted"/webview/assets/sidebar-project-group-signals-*.js; do
    if rg -q '`paths-exist`' "$file"; then
      sidebar_project_file="$file"
      break
    fi
  done

  if [[ -z "$sidebar_project_file" ]]; then
    log "No sidebar project-group bundle found; skipping removable volume probe patch"
    return
  fi

  node - "$sidebar_project_file" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
let changed = false;

function replacePattern(pattern, replacement, label) {
  if (pattern.test(source)) {
    source = source.replace(pattern, () => replacement);
    changed = true;
    return;
  }
  if (!source.includes("startsWith(`/Volumes/`)")) {
    console.warn(`Could not patch removable volume probe: ${label}`);
  }
}

function replaceLiteral(search, replacement, label) {
  if (source.includes(search)) {
    source = source.split(search).join(replacement);
    changed = true;
    return;
  }
  if (!source.includes("startsWith(`/Volumes/`)")) {
    console.warn(`Could not patch removable volume probe: ${label}`);
  }
}

replacePattern(
  /\$e=oe\(M,`paths-exist`,e=>\(\{enabled:e\.length>0,params:\{hostId:l,paths:e\},staleTime:N\.FIVE_SECONDS\}\)\)/,
  "$e=oe(M,`paths-exist`,e=>{let t=e.filter(e=>typeof e!=`string`||!e.startsWith(`/Volumes/`));return{enabled:t.length>0,params:{hostId:l,paths:t},staleTime:N.FIVE_SECONDS}})",
  "paths-exist"
);

replaceLiteral(
  "dirs:z([],t,e(F).data?.roots,[]).find(({hostId:e})=>e===t)?.dirs??Xe",
  "dirs:(z([],t,e(F).data?.roots,[]).find(({hostId:e})=>e===t)?.dirs??Xe).filter(e=>typeof e!=`string`||!e.startsWith(`/Volumes/`))",
  "workspace group dirs"
);

replaceLiteral(
  "params:{hostId:e,dirs:t}",
  "params:{hostId:e,dirs:t.filter(e=>typeof e!=`string`||!e.startsWith(`/Volumes/`))}",
  "workspace task dirs"
);

if (changed) {
  fs.writeFileSync(file, source);
}
NODE

  rg -q 'startsWith\(`/Volumes/`\)' "$sidebar_project_file" ||
    fail "Removable volume probe patch was not applied"
  node --check "$sidebar_project_file" >/dev/null
  log "Patched removable volume sidebar probes: ${sidebar_project_file#$extracted/}"

  for file in "$extracted"/webview/assets/app-server-manager-signals-*.js; do
    if rg -q 'applyRecentConversations' "$file" &&
       rg -q 'applyConversationState' "$file"; then
      server_file="$file"
      break
    fi
  done

  if [[ -n "$server_file" ]]; then
    node - "$server_file" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
let changed = false;

function replaceLiteral(search, replacement, label) {
  if (source.includes(search)) {
    source = source.split(search).join(replacement);
    changed = true;
    return;
  }
  if (!source.includes("CodexHistoryPatchSanitizeConversation")) {
    console.warn(`Could not patch removable volume conversation metadata: ${label}`);
  }
}

if (!source.includes("CodexHistoryPatchSanitizeConversation")) {
  const marker = "}var Ni=class{conversations=new Map;";
  const helper =
    "}function CodexHistoryPatchIsRemovableVolumePath(e){return typeof e==`string`&&e.startsWith(`/Volumes/`)}" +
    "function CodexHistoryPatchSanitizeTurn(e){if(e==null||typeof e!=`object`||!Array.isArray(e.items))return e;let t=!1,n=e.items.map(e=>e!=null&&typeof e==`object`&&CodexHistoryPatchIsRemovableVolumePath(e.cwd)?(t=!0,{...e,cwd:null}):e);return t?{...e,items:n}:e}" +
    "function CodexHistoryPatchSanitizeConversation(e){if(e==null||typeof e!=`object`)return e;let t=e,n=!1;if(CodexHistoryPatchIsRemovableVolumePath(e.cwd)){t={...t,cwd:null,workspaceKind:e.workspaceKind??`projectless`};n=!0}if(Array.isArray(t.turns)){let e=!1,r=t.turns.map(t=>{let n=CodexHistoryPatchSanitizeTurn(t);return n!==t&&(e=!0),n});e&&(t={...t,turns:r},n=!0)}return n?t:e}var Ni=class{conversations=new Map;";
  if (!source.includes(marker)) {
    console.error("Could not insert removable volume conversation sanitizer");
    process.exit(1);
  }
  source = source.replace(marker, helper);
  changed = true;
}

replaceLiteral(
  "getConversationCwd(e){return this.getConversation(e)?.cwd??null}",
  "getConversationCwd(e){let t=this.getConversation(e)?.cwd??null;return CodexHistoryPatchIsRemovableVolumePath(t)?null:t}",
  "getConversationCwd"
);

replaceLiteral(
  "applyRecentConversations(e,t=!0){this.recentConversationsLoaded=t,this.recentConversations=e;",
  "applyRecentConversations(e,t=!0){e=e.map(CodexHistoryPatchSanitizeConversation),this.recentConversationsLoaded=t,this.recentConversations=e;",
  "applyRecentConversations"
);

replaceLiteral(
  "applyConversationState(e,t){if((this.conversations.get(e)??null)!==t){",
  "applyConversationState(e,t){t=CodexHistoryPatchSanitizeConversation(t);if((this.conversations.get(e)??null)!==t){",
  "applyConversationState"
);

if (changed) {
  fs.writeFileSync(file, source);
}
NODE

    rg -q 'CodexHistoryPatchSanitizeConversation' "$server_file" ||
      fail "Removable volume conversation metadata patch was not applied"
    node --check "$server_file" >/dev/null
    log "Patched removable volume conversation metadata: ${server_file#$extracted/}"
  else
    log "No app-server manager bundle found; skipping removable volume conversation metadata patch"
  fi

  for file in "$extracted"/webview/assets/sidebar-thread-list-signals-*.js; do
    if rg -q 'THREAD_WORKSPACE_ROOT_HINTS' "$file" &&
       rg -q 'conversation.cwd' "$file"; then
      sidebar_thread_file="$file"
      break
    fi
  done

  if [[ -n "$sidebar_thread_file" ]]; then
    node - "$sidebar_thread_file" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
const search = "G=m(g,(t,{get:r})=>{let i=r(S,t);return i?.kind===`local`?n({cwd:i.conversation.cwd??null,assignment:s(r,e.THREAD_PROJECT_ASSIGNMENTS)?.[i.conversation.id]}):null})";
const replacement = "G=m(g,(t,{get:r})=>{let i=r(S,t);if(i?.kind!==`local`)return null;let a=i.conversation.cwd??null;return n({cwd:typeof a==`string`&&a.startsWith(`/Volumes/`)?null:a,assignment:s(r,e.THREAD_PROJECT_ASSIGNMENTS)?.[i.conversation.id]})})";

if (source.includes(search)) {
  source = source.split(search).join(replacement);
  fs.writeFileSync(file, source);
} else if (!source.includes("startsWith(`/Volumes/`)?null")) {
  console.warn("Could not patch sidebar thread cwd metadata");
}
NODE

    rg -q 'startsWith\(`/Volumes/`\)\?null' "$sidebar_thread_file" ||
      fail "Sidebar thread cwd metadata patch was not applied"
    node --check "$sidebar_thread_file" >/dev/null
    log "Patched removable volume sidebar thread metadata: ${sidebar_thread_file#$extracted/}"
  else
    log "No sidebar thread-list bundle found; skipping removable volume thread metadata patch"
  fi

  for file in "$extracted"/webview/assets/local-conversation-background-terminals-model-*.js; do
    if rg -q 'restored-process' "$file" &&
       rg -q 'commandExecution' "$file"; then
      background_terminals_file="$file"
      break
    fi
  done

  if [[ -n "$background_terminals_file" ]]; then
    node - "$background_terminals_file" <<'NODE'
const fs = require("fs");

const file = process.argv[2];
let source = fs.readFileSync(file, "utf8");
let changed = false;

function replaceLiteral(search, replacement, label) {
  if (source.includes(search)) {
    source = source.split(search).join(replacement);
    changed = true;
    return;
  }
  if (!source.includes("CodexHistoryPatchCleanCwd")) {
    console.warn(`Could not patch background terminal cwd: ${label}`);
  }
}

if (!source.includes("CodexHistoryPatchCleanCwd")) {
  const marker = "function R(e){let t=[];";
  const helper = "function CodexHistoryPatchCleanCwd(e){return typeof e==`string`&&e.startsWith(`/Volumes/`)?null:e}function R(e){let t=[];";
  if (!source.includes(marker)) {
    console.error("Could not insert background terminal cwd sanitizer");
    process.exit(1);
  }
  source = source.replace(marker, helper);
  changed = true;
}

replaceLiteral("cwd:e.cwd??n.cwd", "cwd:CodexHistoryPatchCleanCwd(e.cwd??n.cwd)", "active/restored command cwd");
replaceLiteral("cwd:e.cwd??t?.cwd??null", "cwd:CodexHistoryPatchCleanCwd(e.cwd??t?.cwd??null)", "restored process cwd");
replaceLiteral("cwd:e.cwd??t.cwd", "cwd:CodexHistoryPatchCleanCwd(e.cwd??t.cwd)", "merged process cwd");
replaceLiteral("cwd:e.cwd??null", "cwd:CodexHistoryPatchCleanCwd(e.cwd??null)", "interrupted command cwd");

if (changed) {
  fs.writeFileSync(file, source);
}
NODE

    rg -q 'CodexHistoryPatchCleanCwd' "$background_terminals_file" ||
      fail "Background terminal cwd patch was not applied"
    node --check "$background_terminals_file" >/dev/null
    log "Patched removable volume background terminal metadata: ${background_terminals_file#$extracted/}"
  else
    log "No background terminal bundle found; skipping removable volume command cwd patch"
  fi
}

patch_bundle_identity() {
  local app="$1"
  local bundle_id="$2"
  local app_name="$3"
  local main_plist="$app/Contents/Info.plist"

  plist_set_or_add_string "$main_plist" "CFBundleIdentifier" "$bundle_id"
  plist_set_or_add_string "$main_plist" "CFBundleName" "$app_name"
  plist_set_or_add_string "$main_plist" "CFBundleDisplayName" "$app_name"
  plist_set_or_add_string "$main_plist" "BundleSigningBaseName" "$app_name"
  plist_set_or_add_string "$main_plist" "CrProductDirName" "$bundle_id"
  add_removable_volumes_usage_descriptions "$app" "$app_name"
  /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName $app_name" "$main_plist" 2>/dev/null || true

  local plist
  local current_id
  while IFS= read -r -d '' plist; do
    current_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$plist" 2>/dev/null || true)"
    case "$current_id" in
      com.openai.codex.framework)
        plist_set_or_add_string "$plist" "CFBundleIdentifier" "${bundle_id}.framework"
        ;;
      com.openai.codex.helper)
        plist_set_or_add_string "$plist" "CFBundleIdentifier" "${bundle_id}.helper"
        ;;
      com.openai.codex.helper.renderer)
        plist_set_or_add_string "$plist" "CFBundleIdentifier" "${bundle_id}.helper.renderer"
        ;;
      com.openai.codex.framework.AlertNotificationService)
        plist_set_or_add_string "$plist" "CFBundleIdentifier" "${bundle_id}.framework.AlertNotificationService"
        ;;
    esac
  done < <(find "$app/Contents/Frameworks" -type f -name Info.plist -print0)

  log "Patched bundle identity to $bundle_id"
}

update_asar_integrity() {
  local app="$1"
  local asar="$app/Contents/Resources/app.asar"
  local plist="$app/Contents/Info.plist"
  local hash

  hash="$(shasum -a 256 "$asar" | awk '{print $1}')"
  if /usr/libexec/PlistBuddy -c 'Print :ElectronAsarIntegrity:Resources/app.asar:hash' "$plist" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$plist"
    log "Updated ElectronAsarIntegrity hash"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE_APP="$2"
      shift 2
      ;;
    --target)
      TARGET_APP="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="$2"
      shift 2
      ;;
    --app-name)
      APP_NAME="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --no-launch)
      LAUNCH_AFTER="0"
      shift
      ;;
    --keep-work)
      KEEP_WORK="1"
      shift
      ;;
    --repair-macos-xattrs)
      REPAIR_MACOS_XATTRS="1"
      shift
      ;;
    --reset-removable-volumes-tcc)
      RESET_REMOVABLE_VOLUMES_TCC="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

[[ "$LIMIT" =~ '^[0-9]+$' ]] || fail "--limit must be a positive integer"
[[ "$LIMIT" -gt 0 ]] || fail "--limit must be greater than zero"

need_cmd ditto
need_cmd npx
need_cmd node
need_cmd rg
need_cmd codesign
need_cmd shasum

SOURCE_APP="$(existing_abs_path "$SOURCE_APP")"
TARGET_APP="$(target_abs_path "$TARGET_APP")"
WORK_DIR="$(target_abs_path "$WORK_DIR")"

[[ "$SOURCE_APP" != "$TARGET_APP" ]] || fail "Source and target app paths must differ"
[[ -f "$SOURCE_APP/Contents/Resources/app.asar" ]] || fail "Source app.asar not found"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
STAGE_ROOT="$WORK_DIR/$RUN_ID"
STAGE_APP="$STAGE_ROOT/$APP_NAME.app"
EXTRACT_DIR="$STAGE_ROOT/app-asar"

log "Source: $SOURCE_APP"
log "Target: $TARGET_APP"
log "Limit: $LIMIT"
log "Bundle id: $BUNDLE_ID"
log "Work dir: $STAGE_ROOT"

if running_under_target_app "$TARGET_APP"; then
  fail "This script appears to be running under the target app. Run it from Terminal, the official Codex app, or another host so the target can be safely stopped and replaced."
fi

rm -rf "$STAGE_ROOT"
mkdir -p "$STAGE_ROOT"

log "Copying source app"
ditto "$SOURCE_APP" "$STAGE_APP"

if [[ "$REPAIR_MACOS_XATTRS" == "1" ]]; then
  repair_macos_xattrs "$STAGE_APP"
fi

log "Extracting app.asar"
npx --yes @electron/asar extract "$STAGE_APP/Contents/Resources/app.asar" "$EXTRACT_DIR"

patch_history_limits "$EXTRACT_DIR" "$LIMIT"
patch_removable_volume_probes "$EXTRACT_DIR"

log "Repacking app.asar"
npx --yes @electron/asar pack "$EXTRACT_DIR" "$STAGE_APP/Contents/Resources/app.asar"

patch_bundle_identity "$STAGE_APP" "$BUNDLE_ID" "$APP_NAME"
update_asar_integrity "$STAGE_APP"

log "Signing patched app"
codesign --force --deep --sign - "$STAGE_APP"
codesign --verify --deep --strict "$STAGE_APP"

stop_processes_for_path "$TARGET_APP"

log "Installing patched app"
rm -rf "$TARGET_APP"
ditto "$STAGE_APP" "$TARGET_APP"

if [[ "$REPAIR_MACOS_XATTRS" == "1" ]]; then
  repair_macos_xattrs "$TARGET_APP"
fi

codesign --verify --deep --strict "$TARGET_APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$TARGET_APP" 2>/dev/null || true
fi

log "Installed $TARGET_APP"
log "Installed bundle id: $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist")"

if [[ "$RESET_REMOVABLE_VOLUMES_TCC" == "1" ]]; then
  reset_removable_volumes_tcc "$BUNDLE_ID"
fi

if [[ "$KEEP_WORK" != "1" ]]; then
  rm -rf "$STAGE_ROOT"
else
  log "Kept work dir: $STAGE_ROOT"
fi

if [[ "$LAUNCH_AFTER" == "1" ]]; then
  log "Launching patched app"
  open -n "$TARGET_APP"
fi
