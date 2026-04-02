#!/usr/bin/env bash
# harness-update.sh — Daily AI harness tool lifecycle manager.
#
# Updates all AI tools, runs per-tool health checks, detects git drift,
# rolls back failures, and sends active notifications.
#
# Usage: bash scripts/cron/harness-update.sh [--dry-run]
# Cron:  Staggered per machine (see schedule-tasks.yaml)
#        dev-primary: 01:15, dev-secondary: 01:45, win-*: 02:15
#
# Exit 0 always (individual tool failures are non-fatal to cron).
# Failures are flagged in summary + notification.
#
# Issues: #1668 (parent), #1672 (Phase 1), #1673 (Phase 2),
#         #1674 (Phase 3), #1675 (Phase 4)
set -uo pipefail

# ── Environment ──────────────────────────────────────────────────────────────
export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${HOME}/.cargo/bin:/usr/local/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_HUB="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${WORKSPACE_HUB}/logs/maintenance"
LOG_FILE="${LOG_DIR}/harness-update-$(date +%Y-%m-%d).log"
TRANSACTION_FILE="${LOG_DIR}/harness-update-transactions.yaml"
DRIFT_POLICY="${WORKSPACE_HUB}/config/agents/drift-policy.yaml"
PATCH_DIR="${WORKSPACE_HUB}/config/agents/hermes/patches"
TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S')"
HOSTNAME_SHORT="$(hostname -s)"

DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

mkdir -p "$LOG_DIR"

# ── Summary accumulators ────────────────────────────────────────────────────
declare -a SUMMARY_TOOL=()
declare -a SUMMARY_BEFORE=()
declare -a SUMMARY_AFTER=()
declare -a SUMMARY_STATUS=()
declare -a SUMMARY_HEALTH=()

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

record() {
  local tool="$1" before="$2" after="$3" status="$4" health="${5:-ok}"
  SUMMARY_TOOL+=("$tool")
  SUMMARY_BEFORE+=("$before")
  SUMMARY_AFTER+=("$after")
  SUMMARY_STATUS+=("$status")
  SUMMARY_HEALTH+=("$health")
}

# ── Transaction logging (Phase 2) ───────────────────────────────────────────

write_transaction() {
  local tool="$1" pre_ver="$2" target_ver="$3" final_ver="$4" status="$5"
  local rollback="${6:-false}" health="${7:-unknown}"
  cat >> "$TRANSACTION_FILE" << EOF
- timestamp: "${TIMESTAMP}"
  machine: "${HOSTNAME_SHORT}"
  tool: "${tool}"
  pre_version: "${pre_ver}"
  target_version: "${target_ver}"
  final_version: "${final_ver}"
  status: "${status}"
  rollback_attempted: ${rollback}
  health: "${health}"
  node_version: "$(node --version 2>/dev/null || echo 'N/A')"
  python_version: "$(python3 --version 2>/dev/null | awk '{print $2}' || echo 'N/A')"
EOF
}

# ── Health check contracts (Phase 1) ────────────────────────────────────────
# Each tool has a non-destructive functional check beyond --version.

health_check_hermes() {
  local venv_python="${HOME}/.hermes/hermes-agent/.venv/bin/python3"
  if [[ ! -x "$venv_python" ]]; then
    log "HEALTH" "Hermes: venv python not found at $venv_python"
    return 1
  fi
  # Verify the import chain that broke in the triggering incident
  if ! "$venv_python" -c "from hermes_cli.main import main; print('ok')" &>/dev/null; then
    log "HEALTH" "Hermes: import chain broken (hermes_cli.main)"
    return 1
  fi
  # Verify hermes binary resolves
  if ! hermes --version &>/dev/null; then
    log "HEALTH" "Hermes: --version failed"
    return 1
  fi
  return 0
}

health_check_claude() {
  if ! claude --version &>/dev/null; then
    log "HEALTH" "Claude Code: --version failed"
    return 1
  fi
  return 0
}

health_check_codex() {
  if ! codex --version &>/dev/null; then
    log "HEALTH" "Codex: --version failed"
    return 1
  fi
  return 0
}

health_check_gemini() {
  if ! gemini --version &>/dev/null; then
    log "HEALTH" "Gemini: --version failed"
    return 1
  fi
  return 0
}

health_check_gstack() {
  local dir="${HOME}/.claude/skills/gstack"
  if ! git -C "$dir" rev-parse HEAD &>/dev/null; then
    log "HEALTH" "GStack: git repo corrupt"
    return 1
  fi
  return 0
}

health_check_superpowers() {
  local dir="${HOME}/.claude/plugins/superpowers"
  if [[ -d "$dir/.git" ]]; then
    if ! git -C "$dir" rev-parse HEAD &>/dev/null; then
      log "HEALTH" "Superpowers: git repo corrupt"
      return 1
    fi
  fi
  return 0
}

health_check_gsd() {
  if ! gsd --version &>/dev/null 2>&1; then
    # gsd may not have --version; check the binary exists
    if ! command -v gsd &>/dev/null; then
      log "HEALTH" "GSD: binary not found"
      return 1
    fi
  fi
  return 0
}

# ── Rollback functions (Phase 2) ────────────────────────────────────────────

rollback_npm() {
  local pkg="$1" previous="$2"
  if [[ -z "$previous" || "$previous" == "not-installed" || "$previous" == "unknown" ]]; then
    log "ROLLBACK" "Cannot rollback $pkg — no previous version recorded"
    return 1
  fi
  log "ROLLBACK" "Restoring $pkg to $previous"
  if npm install -g "${pkg}@${previous}" 2>&1 | tee -a "$LOG_FILE"; then
    local restored
    restored=$(npm list -g "$pkg" --depth=0 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    if [[ "$restored" == "$previous" ]]; then
      log "ROLLBACK" "$pkg restored to $previous — verified"
      return 0
    else
      log "CRITICAL" "$pkg rollback verification FAILED (got $restored, expected $previous)"
      return 1
    fi
  else
    log "CRITICAL" "$pkg rollback install FAILED"
    return 1
  fi
}

rollback_git() {
  local dir="$1" pre_sha="$2"
  if [[ -z "$pre_sha" || "$pre_sha" == "unknown" ]]; then
    log "ROLLBACK" "Cannot rollback $(basename "$dir") — no pre-update SHA"
    return 1
  fi
  log "ROLLBACK" "Restoring $(basename "$dir") to $pre_sha"
  if git -C "$dir" reset --hard "$pre_sha" 2>&1 | tee -a "$LOG_FILE"; then
    log "ROLLBACK" "$(basename "$dir") restored to $pre_sha"
    return 0
  else
    log "CRITICAL" "$(basename "$dir") git reset FAILED"
    return 1
  fi
}

# ── Major version bump guard (Phase 2) ──────────────────────────────────────

is_major_bump() {
  local current="$1" latest="$2"
  local cur_major lat_major
  cur_major=$(echo "$current" | cut -d. -f1)
  lat_major=$(echo "$latest" | cut -d. -f1)
  [[ -n "$cur_major" && -n "$lat_major" && "$cur_major" != "$lat_major" ]]
}

# ── Drift detection (Phase 3) ───────────────────────────────────────────────

check_drift() {
  local tool_dir="$1" tool_name="$2"
  if [[ ! -d "$tool_dir/.git" ]]; then return; fi

  local dirty
  dirty=$(git -C "$tool_dir" status --porcelain 2>/dev/null)
  if [[ -z "$dirty" ]]; then
    log "DRIFT" "$tool_name: clean working tree"
    return
  fi

  local dirty_count
  dirty_count=$(echo "$dirty" | wc -l)
  log "DRIFT" "$tool_name: $dirty_count uncommitted change(s):"

  echo "$dirty" | while IFS= read -r line; do
    local status_code file_path classification
    status_code="${line:0:2}"
    file_path="${line:3}"
    classification="unclassified"

    # Classify against drift-policy.yaml (simple pattern matching)
    if [[ -f "$DRIFT_POLICY" ]]; then
      local tool_key
      tool_key=$(echo "$tool_name" | tr '[:upper:]' '[:lower:]')
      # Check machine_specific
      if grep -A2 "machine_specific:" "$DRIFT_POLICY" | grep -q "path: \"$file_path\"" 2>/dev/null; then
        classification="machine_specific"
      # Check portable
      elif grep -A2 "portable:" "$DRIFT_POLICY" | grep -q "path: \"$file_path\"" 2>/dev/null; then
        classification="portable"
      # Check never_sync
      elif grep "never_sync:" -A20 "$DRIFT_POLICY" | grep -q "\"$file_path\"" 2>/dev/null; then
        classification="never_sync"
      fi
    fi

    log "DRIFT" "  $status_code $file_path [$classification]"
  done
}

# ── Per-tool update functions ────────────────────────────────────────────────

update_gstack() {
  local dir="${HOME}/.claude/skills/gstack"
  if [[ ! -d "$dir/.git" ]]; then
    log "GStack: not installed at ${dir} — skipping"
    record "GStack" "-" "-" "not-installed"
    return
  fi
  local before after pre_sha
  before=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  pre_sha=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")
  if [[ "$DRY_RUN" == "true" ]]; then
    log "GStack: [dry-run] would git pull --rebase --autostash in ${dir}"
    record "GStack" "$before" "(dry-run)" "dry-run"
    return
  fi
  log "GStack: updating via git pull --rebase --autostash"
  if git -C "$dir" pull --rebase --autostash 2>&1 | tee -a "$LOG_FILE"; then
    after=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    # Health check
    if health_check_gstack; then
      local update_status
      if [[ "$before" == "$after" ]]; then
        update_status="up-to-date"
      else
        update_status="updated"
      fi
      log "GStack: ${update_status} (${before} -> ${after})"
      record "GStack" "$before" "$after" "$update_status" "healthy"
      write_transaction "gstack" "$before" "latest" "$after" "$update_status" "false" "healthy"
    else
      log "CRITICAL" "GStack: BROKEN after update — rolling back"
      rollback_git "$dir" "$pre_sha"
      after=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      record "GStack" "$before" "$after" "BROKEN-rollback" "broken"
      write_transaction "gstack" "$before" "latest" "$after" "rollback" "true" "broken"
    fi
  else
    after=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    log "GStack: git pull failed"
    record "GStack" "$before" "$after" "failed" "unknown"
    write_transaction "gstack" "$before" "latest" "$after" "failed" "false" "unknown"
  fi
  check_drift "$dir" "GStack"
}

update_hermes() {
  if ! command -v hermes &>/dev/null; then
    log "Hermes: not installed — skipping"
    record "Hermes" "-" "-" "not-installed"
    return
  fi
  local before after pre_sha hermes_dir="${HOME}/.hermes/hermes-agent"
  before=$(hermes --version 2>/dev/null | head -1 || echo "installed")
  pre_sha=$(git -C "$hermes_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Hermes: [dry-run] would run hermes update"
    record "Hermes" "$before" "(dry-run)" "dry-run"
    return
  fi
  log "Hermes: updating via hermes update"
  if hermes update 2>&1 | tee -a "$LOG_FILE"; then
    # Apply local patches from repo (Phase 2 — replaces fork)
    if [[ -d "$PATCH_DIR" ]]; then
      for patch_file in "$PATCH_DIR"/*.patch; do
        [[ -f "$patch_file" ]] || continue
        if git -C "$hermes_dir" apply --check "$patch_file" 2>/dev/null; then
          git -C "$hermes_dir" apply "$patch_file" 2>&1 | tee -a "$LOG_FILE"
          log "PATCH" "Applied $(basename "$patch_file")"
        else
          log "PATCH" "$(basename "$patch_file") — skipped (already applied or conflict)"
        fi
      done
    fi

    after=$(hermes --version 2>/dev/null | head -1 || echo "unknown")
    # Health check — the one that would have caught the dotenv crash
    if health_check_hermes; then
      local update_status
      if [[ "$before" == "$after" ]]; then
        update_status="up-to-date"
      else
        update_status="updated"
      fi
      log "Hermes: ${update_status} (${before} -> ${after})"
      record "Hermes" "$before" "$after" "$update_status" "healthy"
      write_transaction "hermes" "$before" "latest" "$after" "$update_status" "false" "healthy"
    else
      log "CRITICAL" "Hermes: BROKEN after update — rolling back to ${pre_sha}"
      rollback_git "$hermes_dir" "$pre_sha"
      after=$(hermes --version 2>/dev/null | head -1 || echo "rollback")
      record "Hermes" "$before" "$after" "BROKEN-rollback" "broken"
      write_transaction "hermes" "$before" "latest" "$after" "rollback" "true" "broken"
    fi
  else
    after=$(hermes --version 2>/dev/null | head -1 || echo "unknown")
    log "Hermes: update failed"
    record "Hermes" "$before" "$after" "failed" "unknown"
    write_transaction "hermes" "$before" "latest" "$after" "failed" "false" "unknown"
  fi
  check_drift "$hermes_dir" "Hermes"
}

update_superpowers() {
  if ! command -v claude &>/dev/null; then
    log "Superpowers: claude CLI not installed — skipping"
    record "Superpowers" "-" "-" "not-installed"
    return
  fi
  local before sp_installed=false
  if claude plugin list 2>/dev/null | grep -qi superpowers; then
    sp_installed=true
    before=$(claude plugin list 2>/dev/null | grep -i superpowers | sed 's/^[[:space:]]*[^a-zA-Z]*//' | head -1)
  fi
  if [[ "$sp_installed" == "false" ]]; then
    local sp_dir="${HOME}/.claude/plugins/superpowers"
    if [[ -d "$sp_dir/.git" ]]; then
      sp_installed=true
      before=$(git -C "$sp_dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    else
      log "Superpowers: not installed — skipping"
      record "Superpowers" "-" "-" "not-installed"
      return
    fi
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "Superpowers: [dry-run] would run claude plugin update superpowers"
    record "Superpowers" "$before" "(dry-run)" "dry-run"
    return
  fi
  log "Superpowers: updating via claude plugin update superpowers"
  local after
  if timeout 60 claude plugin update superpowers 2>&1 | tee -a "$LOG_FILE"; then
    after=$(claude plugin list 2>/dev/null | grep -i superpowers | head -1 || echo "unknown")
    if health_check_superpowers; then
      log "Superpowers: update complete (${before} -> ${after})"
      record "Superpowers" "$before" "$after" "updated" "healthy"
      write_transaction "superpowers" "$before" "latest" "$after" "updated" "false" "healthy"
    else
      log "CRITICAL" "Superpowers: BROKEN after update"
      record "Superpowers" "$before" "$after" "BROKEN" "broken"
      write_transaction "superpowers" "$before" "latest" "$after" "broken" "false" "broken"
    fi
  else
    log "Superpowers: update failed or timed out"
    record "Superpowers" "$before" "-" "failed" "unknown"
    write_transaction "superpowers" "$before" "latest" "-" "failed" "false" "unknown"
  fi
}

# ── Generic npm update with major-bump guard + rollback (Phase 1+2) ─────────

update_npm_tool() {
  local tool_name="$1" pkg="$2" health_fn="$3"
  if ! command -v npm &>/dev/null; then
    log "${tool_name}: npm not installed — skipping"
    record "$tool_name" "-" "-" "not-installed"
    return
  fi
  local before after latest
  before=$(npm list -g "$pkg" --depth=0 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "not-installed")
  if [[ "$before" == "not-installed" ]]; then
    log "${tool_name}: not installed globally — skipping"
    record "$tool_name" "-" "-" "not-installed"
    return
  fi
  latest=$(npm view "$pkg" version 2>/dev/null || echo "unknown")

  # Major version bump guard (Phase 2)
  if [[ "$latest" != "unknown" ]] && is_major_bump "$before" "$latest"; then
    log "WARN" "${tool_name}: major version bump ${before} -> ${latest} — skipping (manual review required)"
    record "$tool_name" "$before" "$latest" "major-bump-skipped"
    write_transaction "$tool_name" "$before" "$latest" "$before" "major-bump-skipped" "false" "healthy"
    return
  fi

  if [[ "$before" == "$latest" ]]; then
    log "${tool_name}: already at latest (${before})"
    record "$tool_name" "$before" "$latest" "up-to-date" "healthy"
    write_transaction "$tool_name" "$before" "$latest" "$before" "up-to-date" "false" "healthy"
    return
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "${tool_name}: [dry-run] would npm install -g ${pkg}@latest (${before} -> ${latest})"
    record "$tool_name" "$before" "(dry-run: ${latest})" "dry-run"
    return
  fi
  log "${tool_name}: updating ${before} -> ${latest}"
  if npm install -g "${pkg}@latest" 2>&1 | tee -a "$LOG_FILE"; then
    after=$(npm list -g "$pkg" --depth=0 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    # Health check (Phase 1)
    if $health_fn; then
      log "${tool_name}: updated to ${after} — healthy"
      record "$tool_name" "$before" "$after" "updated" "healthy"
      write_transaction "$tool_name" "$before" "$latest" "$after" "updated" "false" "healthy"
    else
      log "CRITICAL" "${tool_name}: BROKEN after update — rolling back to ${before}"
      local rollback_ok=false
      if rollback_npm "$pkg" "$before"; then
        rollback_ok=true
      fi
      after=$(npm list -g "$pkg" --depth=0 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
      if [[ "$rollback_ok" == "true" ]]; then
        record "$tool_name" "$before" "$after" "BROKEN-rollback" "broken"
        write_transaction "$tool_name" "$before" "$latest" "$after" "rollback" "true" "broken"
      else
        record "$tool_name" "$before" "$after" "BROKEN-rollback-failed" "broken"
        write_transaction "$tool_name" "$before" "$latest" "$after" "rollback-failed" "true" "broken"
      fi
    fi
  else
    after=$(npm list -g "$pkg" --depth=0 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    log "${tool_name}: npm install failed"
    record "$tool_name" "$before" "$after" "failed" "unknown"
    write_transaction "$tool_name" "$before" "$latest" "$after" "failed" "false" "unknown"
  fi
}

update_gsd() { update_npm_tool "GSD" "get-shit-done-cc" health_check_gsd; }
update_claude_code() { update_npm_tool "Claude Code" "@anthropic-ai/claude-code" health_check_claude; }
update_codex() { update_npm_tool "Codex" "@openai/codex" health_check_codex; }
update_gemini() { update_npm_tool "Gemini CLI" "@google/gemini-cli" health_check_gemini; }

# ── Summary table ────────────────────────────────────────────────────────────

print_summary() {
  local sep="+-----------------+----------------------+----------------------+---------------------+----------+"
  log ""
  log "═══ Harness Update Summary (${HOSTNAME_SHORT}) ═══"
  log "$sep"
  printf "| %-15s | %-20s | %-20s | %-19s | %-8s |\n" "Tool" "Before" "After" "Status" "Health" | tee -a "$LOG_FILE"
  log "$sep"
  for i in "${!SUMMARY_TOOL[@]}"; do
    printf "| %-15s | %-20s | %-20s | %-19s | %-8s |\n" \
      "${SUMMARY_TOOL[$i]}" "${SUMMARY_BEFORE[$i]}" "${SUMMARY_AFTER[$i]}" \
      "${SUMMARY_STATUS[$i]}" "${SUMMARY_HEALTH[$i]:-ok}" \
      | tee -a "$LOG_FILE"
  done
  log "$sep"
}

# ── Notification (Phase 1 — active alerting) ─────────────────────────────────

send_notification() {
  local fail_count=0 broken_count=0 tool_details=""
  for i in "${!SUMMARY_STATUS[@]}"; do
    local s="${SUMMARY_STATUS[$i]}"
    local h="${SUMMARY_HEALTH[$i]:-ok}"
    [[ "$s" == "failed" ]] && ((fail_count++)) || true
    [[ "$h" == "broken" ]] && ((broken_count++)) || true
    if [[ "$s" == "failed" || "$h" == "broken" || "$s" == *"BROKEN"* || "$s" == *"rollback"* ]]; then
      tool_details="${tool_details}${SUMMARY_TOOL[$i]}:${s}(${h}), "
    fi
  done

  local overall_status="pass"
  if [[ "$broken_count" -gt 0 ]]; then
    overall_status="fail"
  elif [[ "$fail_count" -gt 0 ]]; then
    overall_status="warn"
  fi

  local details="machine=${HOSTNAME_SHORT},tools=${#SUMMARY_TOOL[@]},failed=${fail_count},broken=${broken_count}"
  if [[ -n "$tool_details" ]]; then
    details="${details},failures=${tool_details%, }"
  fi

  if [[ "$DRY_RUN" != "true" && -f "${WORKSPACE_HUB}/scripts/notify.sh" ]]; then
    bash "${WORKSPACE_HUB}/scripts/notify.sh" cron harness-update "$overall_status" "$details" 2>/dev/null || true
  fi

  # Log failure summary prominently for tools that write to syslog/journal
  if [[ "$broken_count" -gt 0 ]]; then
    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  ⚠  BROKEN TOOLS DETECTED — MANUAL INTERVENTION NEEDED ║"
    log "║  Machine: ${HOSTNAME_SHORT}"
    log "║  Broken: ${tool_details%, }"
    log "╚══════════════════════════════════════════════════════════╝"
    # Write to system journal if available
    if command -v logger &>/dev/null; then
      logger -t harness-update -p user.err \
        "BROKEN tools on ${HOSTNAME_SHORT}: ${tool_details%, }" 2>/dev/null || true
    fi
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "==========================================="
log "Harness Update — ${TIMESTAMP} (${HOSTNAME_SHORT})"
[[ "$DRY_RUN" == "true" ]] && log "MODE: dry-run (no changes)"
log "==========================================="

# Runtime version baseline (Phase 2)
log "Runtime: node=$(node --version 2>/dev/null || echo 'N/A') npm=$(npm --version 2>/dev/null || echo 'N/A') python=$(python3 --version 2>/dev/null | awk '{print $2}' || echo 'N/A')"

# Update all tools (Phase 1: all 7 covered)
update_gstack
update_hermes
update_superpowers
update_gsd
update_claude_code
update_codex
update_gemini

print_summary
send_notification

log ""
log "Completed at $(date '+%Y-%m-%dT%H:%M:%S')"

# Retain 30 days of logs
find "$LOG_DIR" -name "harness-update-*.log" -mtime +30 -delete 2>/dev/null || true
# Retain 90 days of transaction logs
find "$LOG_DIR" -name "harness-update-transactions*.yaml" -mtime +90 -delete 2>/dev/null || true

exit 0
