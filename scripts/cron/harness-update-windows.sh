#!/usr/bin/env bash
# harness-update-windows.sh — AI harness update for Windows machines (Git Bash / MINGW64).
#
# Subset of harness-update.sh adapted for Windows constraints:
# - Only npm-global tools (Claude Code, Codex, Gemini CLI) — no Hermes/GStack/Superpowers
# - Windows paths: uses $APPDATA/npm for global packages
# - No cron: designed for Task Scheduler via Git Bash
#
# Usage (Git Bash): bash scripts/cron/harness-update-windows.sh [--dry-run]
# Task Scheduler: "C:\Program Files\Git\bin\bash.exe" -l -c "cd D:/workspace-hub && bash scripts/cron/harness-update-windows.sh"
#
# Issues: #1668 (parent), #1675 (Phase 4)
set -uo pipefail

# ── Environment ──────────────────────────────────────────────────────────────
# Git Bash on Windows: npm global bin may be in APPDATA
if [[ -n "${APPDATA:-}" ]]; then
  NPM_GLOBAL="$(cygpath "$APPDATA")/npm"
  export PATH="${NPM_GLOBAL}:${PATH}"
fi
export PATH="${HOME}/.local/bin:${HOME}/.npm-global/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_HUB="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LOG_DIR="${WORKSPACE_HUB}/logs/maintenance"
LOG_FILE="${LOG_DIR}/harness-update-$(date +%Y-%m-%d).log"
TRANSACTION_FILE="${LOG_DIR}/harness-update-transactions.yaml"
TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S')"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo "${COMPUTERNAME:-unknown}")"

DRY_RUN=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=true
done

mkdir -p "$LOG_DIR"

# ── Accumulators ─────────────────────────────────────────────────────────────
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
EOF
}

# ── Health checks ────────────────────────────────────────────────────────────

health_check_claude() { claude --version &>/dev/null; }
health_check_codex() { codex --version &>/dev/null; }
health_check_gemini() { gemini --version &>/dev/null; }

# ── Major version guard ─────────────────────────────────────────────────────

is_major_bump() {
  local current="$1" latest="$2"
  local cur_major lat_major
  cur_major=$(echo "$current" | cut -d. -f1)
  lat_major=$(echo "$latest" | cut -d. -f1)
  [[ -n "$cur_major" && -n "$lat_major" && "$cur_major" != "$lat_major" ]]
}

# ── Rollback ─────────────────────────────────────────────────────────────────

rollback_npm() {
  local pkg="$1" previous="$2"
  if [[ -z "$previous" || "$previous" == "not-installed" || "$previous" == "unknown" ]]; then
    log "ROLLBACK" "Cannot rollback $pkg — no previous version"
    return 1
  fi
  log "ROLLBACK" "Restoring $pkg to $previous"
  if npm install -g "${pkg}@${previous}" 2>&1 | tee -a "$LOG_FILE"; then
    local restored
    restored=$(npm list -g "$pkg" --depth=0 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    if [[ "$restored" == "$previous" ]]; then
      log "ROLLBACK" "$pkg restored to $previous — verified"
      return 0
    fi
  fi
  log "CRITICAL" "$pkg rollback FAILED"
  return 1
}

# ── Windows .cmd shim verification ───────────────────────────────────────────

verify_cmd_shim() {
  local tool_name="$1" cmd_name="$2"
  if [[ -n "${APPDATA:-}" ]]; then
    local shim_path="$(cygpath "$APPDATA")/npm/${cmd_name}.cmd"
    if [[ -f "$shim_path" ]]; then
      log "SHIM" "${tool_name}: .cmd shim OK at ${shim_path}"
      return 0
    else
      log "WARN" "${tool_name}: .cmd shim MISSING at ${shim_path}"
      return 1
    fi
  fi
  return 0  # Not on Windows or no APPDATA
}

# ── Generic npm update ───────────────────────────────────────────────────────

update_npm_tool() {
  local tool_name="$1" pkg="$2" health_fn="$3" cmd_name="${4:-}"
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

  if [[ "$latest" != "unknown" ]] && is_major_bump "$before" "$latest"; then
    log "WARN" "${tool_name}: major version bump ${before} -> ${latest} — skipping"
    record "$tool_name" "$before" "$latest" "major-bump-skipped"
    write_transaction "$tool_name" "$before" "$latest" "$before" "major-bump-skipped" "false" "healthy"
    return
  fi
  if [[ "$before" == "$latest" ]]; then
    log "${tool_name}: already at latest (${before})"
    # Still verify .cmd shim on Windows
    if [[ -n "$cmd_name" ]]; then verify_cmd_shim "$tool_name" "$cmd_name"; fi
    record "$tool_name" "$before" "$latest" "up-to-date" "healthy"
    write_transaction "$tool_name" "$before" "$latest" "$before" "up-to-date" "false" "healthy"
    return
  fi
  if [[ "$DRY_RUN" == "true" ]]; then
    log "${tool_name}: [dry-run] would update ${before} -> ${latest}"
    record "$tool_name" "$before" "(dry-run: ${latest})" "dry-run"
    return
  fi
  log "${tool_name}: updating ${before} -> ${latest}"
  if npm install -g "${pkg}@latest" 2>&1 | tee -a "$LOG_FILE"; then
    after=$(npm list -g "$pkg" --depth=0 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    # Verify .cmd shim
    if [[ -n "$cmd_name" ]]; then verify_cmd_shim "$tool_name" "$cmd_name"; fi
    # Health check
    if $health_fn; then
      log "${tool_name}: updated to ${after} — healthy"
      record "$tool_name" "$before" "$after" "updated" "healthy"
      write_transaction "$tool_name" "$before" "$latest" "$after" "updated" "false" "healthy"
    else
      log "CRITICAL" "${tool_name}: BROKEN — rolling back to ${before}"
      local rollback_ok=false
      rollback_npm "$pkg" "$before" && rollback_ok=true
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

# ── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
  local sep="+-----------------+----------------------+----------------------+---------------------+----------+"
  log ""
  log "═══ Harness Update Summary (${HOSTNAME_SHORT} — Windows) ═══"
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

send_notification() {
  local fail_count=0 broken_count=0
  for i in "${!SUMMARY_STATUS[@]}"; do
    [[ "${SUMMARY_STATUS[$i]}" == "failed" ]] && ((fail_count++)) || true
    [[ "${SUMMARY_HEALTH[$i]:-ok}" == "broken" ]] && ((broken_count++)) || true
  done
  local overall_status="pass"
  [[ "$broken_count" -gt 0 ]] && overall_status="fail"
  [[ "$fail_count" -gt 0 && "$overall_status" == "pass" ]] && overall_status="warn"

  if [[ "$DRY_RUN" != "true" && -f "${WORKSPACE_HUB}/scripts/notify.sh" ]]; then
    bash "${WORKSPACE_HUB}/scripts/notify.sh" cron harness-update "$overall_status" \
      "machine=${HOSTNAME_SHORT},tools=${#SUMMARY_TOOL[@]},failed=${fail_count},broken=${broken_count}" 2>/dev/null || true
  fi
  if [[ "$broken_count" -gt 0 ]]; then
    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  ⚠  BROKEN TOOLS DETECTED — MANUAL INTERVENTION NEEDED ║"
    log "║  Machine: ${HOSTNAME_SHORT} (Windows)"
    log "╚══════════════════════════════════════════════════════════╝"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

log "==========================================="
log "Harness Update — ${TIMESTAMP} (${HOSTNAME_SHORT} — Windows)"
[[ "$DRY_RUN" == "true" ]] && log "MODE: dry-run (no changes)"
log "==========================================="
log "Runtime: node=$(node --version 2>/dev/null || echo 'N/A') npm=$(npm --version 2>/dev/null || echo 'N/A')"

# Windows machines: Claude Code, Codex, Gemini CLI only
# (per registry.yaml agent_clis for licensed-win-1, licensed-win-2)
update_npm_tool "Claude Code" "@anthropic-ai/claude-code" health_check_claude "claude"
update_npm_tool "Codex" "@openai/codex" health_check_codex "codex"
update_npm_tool "Gemini CLI" "@google/gemini-cli" health_check_gemini "gemini"

print_summary
send_notification

log ""
log "Completed at $(date '+%Y-%m-%dT%H:%M:%S')"

# Retain 30 days of logs
find "$LOG_DIR" -name "harness-update-*.log" -mtime +30 -delete 2>/dev/null || true

exit 0
