#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod + Strata bootstrap
# Qwen3.8-Flash-Next IQ3_S
# RTX 3090 / EPYC tuned profile
# ============================================================

STRATA_DIR="/workspace/Strata"
CONFIG="$STRATA_DIR/strata-iq3_s.json"
RUN_SCRIPT="$STRATA_DIR/run-iq3_s.sh"

KEY_FILE="/workspace/.strata-api-key"
PID_FILE="/workspace/.strata-server.pid"
LOG_FILE="$STRATA_DIR/strata-server.out"

PORT=8000
CONTEXT=131072

echo
echo "========================================"
echo " Strata IQ3_S RunPod bootstrap"
echo "========================================"
echo

# ------------------------------------------------------------
# Basic dependencies
# ------------------------------------------------------------

missing=()

command -v git >/dev/null 2>&1 || missing+=(git)
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v python3 >/dev/null 2>&1 || missing+=(python3)

if (( ${#missing[@]} )); then
    echo "[+] Installing missing dependencies: ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi

# ------------------------------------------------------------
# Generate / reuse Strata API key
# ------------------------------------------------------------

umask 077

if [[ -n "${STRATA_API_KEY:-}" ]]; then
    echo "[+] Using STRATA_API_KEY from environment"
    printf '%s\n' "$STRATA_API_KEY" > "$KEY_FILE"

elif [[ -s "$KEY_FILE" ]]; then
    STRATA_API_KEY="$(cat "$KEY_FILE")"
    export STRATA_API_KEY
    echo "[+] Reusing existing Strata API key"

else
    STRATA_API_KEY="$(
        python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
    )"

    export STRATA_API_KEY
    printf '%s\n' "$STRATA_API_KEY" > "$KEY_FILE"

    echo "[+] Generated new Strata API key"
fi

chmod 600 "$KEY_FILE"

# ------------------------------------------------------------
# Clone / update Strata
# ------------------------------------------------------------

if [[ ! -d "$STRATA_DIR/.git" ]]; then
    echo "[+] Cloning Strata"
    cd /workspace
    git clone https://github.com/Niko1221/Strata.git
else
    echo "[+] Existing Strata checkout found"
    cd "$STRATA_DIR"

    # Update only if clean. Don't destroy local modifications.
    if [[ -z "$(git status --porcelain)" ]]; then
        echo "[+] Updating Strata"
        git pull --ff-only || true
    else
        echo "[!] Local modifications detected; skipping git pull"
    fi
fi

cd "$STRATA_DIR"

echo "[+] Strata commit: $(git rev-parse --short HEAD)"

# ------------------------------------------------------------
# Setup model
# ------------------------------------------------------------

echo
echo "[+] Setting up:"
echo "    Model   : IQ3_S"
echo "    Context : $CONTEXT"
echo "    Vision  : GPU"
echo "    Host    : 0.0.0.0"
echo "    Port    : $PORT"
echo

./setup.sh --yes \
    --family qwen \
    --model IQ3_S \
    --context "$CONTEXT" \
    --vision gpu \
    --host 0.0.0.0 \
    --port "$PORT" \
    --api-key "$STRATA_API_KEY" \
    --no-start

# ------------------------------------------------------------
# Apply known-good RTX 3090 / EPYC tuning
# ------------------------------------------------------------

echo
echo "[+] Applying tuned Strata settings"

python3 - "$CONFIG" "$STRATA_API_KEY" "$PORT" <<'PY'
import json
import sys

path = sys.argv[1]
api_key = sys.argv[2]
port = int(sys.argv[3])

with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

args = cfg.setdefault("args", [])

tuning = {
    "--pcie-frac": "0.00",
    "--spec-min-p": "0.70",
    "--pool-workers": "64",
}

for option, value in tuning.items():
    if option in args:
        i = args.index(option)

        if i + 1 < len(args):
            args[i + 1] = value
        else:
            args.append(value)
    else:
        args.extend([option, value])

cfg["host"] = "0.0.0.0"
cfg["port"] = port
cfg["api_key"] = api_key

with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2)

print("[+] Config patched:")
for option, value in tuning.items():
    print(f"    {option} {value}")

print(f"    host = {cfg['host']}")
print(f"    port = {cfg['port']}")
PY

# ------------------------------------------------------------
# Safety: ensure generated launcher also uses port 8000
# ------------------------------------------------------------

if [[ -f "$RUN_SCRIPT" ]]; then
    sed -i \
        -e 's/--port" "8080"/--port" "8000"/g' \
        -e 's/--port 8080/--port 8000/g' \
        "$RUN_SCRIPT"
fi

# ------------------------------------------------------------
# Shared defaults for clients such as Goose
#
# low:
#   keep reasoning enabled, but discourage huge thinking runs.
# max_tokens:
#   prevents a single agent turn from having ~100k output budget.
# ------------------------------------------------------------

cat > "$STRATA_DIR/strata-iq3_s.shared-settings.json" <<'JSON'
{
  "reasoning_effort": "low",
  "max_tokens": 8192
}
JSON

echo "[+] Shared defaults:"
echo "    reasoning_effort = low"
echo "    max_tokens       = 8192"

# ------------------------------------------------------------
# Don't start a duplicate server
# ------------------------------------------------------------

if curl -fsS \
    -H "Authorization: Bearer $STRATA_API_KEY" \
    "http://127.0.0.1:${PORT}/v1/models" \
    >/dev/null 2>&1
then
    echo
    echo "[+] Strata is already running on port $PORT"
else
    echo
    echo "[+] Starting Strata"

    cd "$STRATA_DIR"

    export STRATA_ARENA_PIN_GIB=8

    nohup env \
        STRATA_ARENA_PIN_GIB=8 \
        ./run-iq3_s.sh \
        > "$LOG_FILE" 2>&1 &

    STRATA_PID=$!
    printf '%s\n' "$STRATA_PID" > "$PID_FILE"

    echo "[+] PID: $STRATA_PID"
fi

# ------------------------------------------------------------
# Save useful environment helper for this Pod
# ------------------------------------------------------------

cat > /workspace/strata-env.sh <<EOF
export STRATA_API_KEY="\$(cat /workspace/.strata-api-key)"
export OPENAI_API_KEY="\$STRATA_API_KEY"

export OPENAI_HOST="http://127.0.0.1:${PORT}"
export OPENAI_BASE_PATH="v1/chat/completions"

export GOOSE_PROVIDER="openai"
export GOOSE_MODEL="qwen3.8-flash-next-iq3_s"
export GOOSE_CONTEXT_LIMIT=32768
export GOOSE_THINKING_EFFORT=off
EOF

chmod 600 /workspace/strata-env.sh

# ------------------------------------------------------------
# Final information
# ------------------------------------------------------------

echo
echo "========================================"
echo " Bootstrap complete"
echo "========================================"
echo
echo "Strata:"
echo "  http://127.0.0.1:${PORT}"
echo
echo "RunPod HTTP port:"
echo "  ${PORT}"
echo
echo "API key stored at:"
echo "  $KEY_FILE"
echo
echo "Show API key:"
echo "  cat $KEY_FILE"
echo
echo "Follow startup:"
echo "  tail -f $LOG_FILE"
echo
echo "Check models:"
echo "  curl -s http://127.0.0.1:${PORT}/v1/models \\"
echo '    -H "Authorization: Bearer $(cat /workspace/.strata-api-key)"'
echo
echo "Load environment:"
echo "  source /workspace/strata-env.sh"
echo
echo "NOTE:"
echo "  First model load can take several minutes."
echo
