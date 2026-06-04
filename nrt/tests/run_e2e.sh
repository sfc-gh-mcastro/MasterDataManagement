#!/usr/bin/env bash
# =============================================================================
# run_e2e.sh — Run the NRT MDM E2E test with proper Python environment
# Ensures Docker containers are running and test data exists before executing.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
VENV_DIR="$PROJECT_DIR/.venv"
BULK_DIR="$REPO_DIR/bulk"
SHARED_DIR="$REPO_DIR/shared"

# --- Ensure Docker stack is running ---
echo "[docker] Checking containers..."
if ! docker compose -f "$PROJECT_DIR/docker-compose.yml" ps --status running 2>/dev/null | grep -q "postgres"; then
    echo "[docker] Starting stack..."
    docker compose -f "$PROJECT_DIR/docker-compose.yml" up -d postgres kafka mdm-engine
    echo "[docker] Waiting for services to be healthy..."
    sleep 10
fi
echo "[docker] OK"

# --- Python venv ---
if [ ! -d "$VENV_DIR" ]; then
    echo "[venv] Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

if ! python -c "import nrt_mdm" 2>/dev/null; then
    echo "[venv] Installing nrt-mdm package..."
    pip install -q -e "$PROJECT_DIR[dev]"
fi

# --- Generate bulk test data if not present ---
if [ ! -d "$SHARED_DIR/output/initial" ]; then
    echo "[data] Generating bulk test data (1,500 records)..."
    python3 "$SHARED_DIR/scripts/generate_test_data.py"
    echo "[data] OK"
fi

# --- Run E2E test ---
echo ""
python "$SCRIPT_DIR/e2e_test.py" "$@"
