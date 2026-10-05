#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# RunPod Strata bootstrap
#
# Target:
#   GPU     : RTX 3090
#   Model   : Qwen3.8-Flash-Next IQ3_S
#   Vision  : GPU
#   Context : 131072
#
# Uses our own prebuilt Strata engine.
# Local compilation is not expected.
# ============================================================


# ------------------------------------------------------------
# Fixed versions
# ------------------------------------------------------------

STRATA_COMMIT="6f32ec070f23ced9f50e704d854d775da52591ab"

PREBUILT_TAG="strata-0.1.39-rtx3090"
PREBUILT_NAME="strata-linux-x64.zip"

PREBUILT_BASE="https://github.com/xtq62/runpod-strata-bootup/releases/download/${PREBUILT_TAG}"
PREBUILT_URL="${PREBUILT_BASE}/${PREBUILT_NAME}"

PREBUILT_SHA256="7d590485141f0a1b6109f01003381ee188a05f0d1fe94e92cf66b26e11f5e6e3"


# ------------------------------------------------------------
# Settings
# ------------------------------------------------------------

WORKSPACE="/workspace"
STRATA_DIR="${WORKSPACE}/Strata"
ENGINE_DIR="${STRATA_DIR}/engine"

KEY_FILE="${WORKSPACE}/.strata-api-key"

CACHE_DIR="${WORKSPACE}/.cache/runpod-strata"
PREBUILT_ZIP="${CACHE_DIR}/${PREBUILT_NAME}"

CONFIG="${STRATA_DIR}/strata-iq3_s.json"
RUN_SCRIPT="${STRATA_DIR}/run-iq3_s.sh"

LOG_FILE="${STRATA_DIR}/strata-server.out"
PID_FILE="${WORKSPACE}/.strata-server.pid"

PORT="8000"
CONTEXT="131072"


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

info() {
    echo "[+] $*"
}

warn() {
    echo "[!] $*" >&2
}

die() {
    echo "[-] $*" >&2
    exit 1
}


echo
echo "=============================================="
echo " Strata RTX 3090 / IQ3_S bootstrap"
echo "=============================================="
echo


# ------------------------------------------------------------
# Basic dependencies
# ------------------------------------------------------------

missing=()

command -v git >/dev/null 2>&1 || missing+=(git)
command -v curl >/dev/null 2>&1 || missing+=(curl)
command -v unzip >/dev/null 2>&1 || missing+=(unzip)
command -v python3 >/dev/null 2>&1 || missing+=(python3)

if (( ${#missing[@]} )); then
    info "Installing dependencies: ${missing[*]}"

    apt-get update
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y "${missing[@]}" ca-certificates
fi


# ------------------------------------------------------------
# Check GPU
#
# This prebuilt was compiled for RTX 3090 / sm_86.
# Abort instead of silently compiling for another GPU.
# ------------------------------------------------------------

command -v nvidia-smi >/dev/null 2>&1 \
    || die "nvidia-smi not found"

GPU_NAME="$(
    nvidia-smi \
        --query-gpu=name \
        --format=csv,noheader \
        | head -n1 \
        | xargs
)"

info "GPU: ${GPU_NAME}"

if [[ "$GPU_NAME" != *"RTX 3090"* ]]; then
    die "This bootstrap is for RTX 3090. Refusing to use the sm_86 prebuilt on: ${GPU_NAME}"
fi


# ------------------------------------------------------------
# Generate/reuse Strata API key
# ------------------------------------------------------------

umask 077

if [[ -n "${STRATA_API_KEY:-}" ]]; then

    info "Using STRATA_API_KEY from environment"

    printf '%s\n' "$STRATA_API_KEY" > "$KEY_FILE"

elif [[ -s "$KEY_FILE" ]]; then

    STRATA_API_KEY="$(cat "$KEY_FILE")"
    export STRATA_API_KEY

    info "Reusing existing Strata API key"

else

    STRATA_API_KEY="$(
        python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
    )"

    export STRATA_API_KEY

    printf '%s\n' "$STRATA_API_KEY" > "$KEY_FILE"

    info "Generated new Strata API key"
fi

chmod 600 "$KEY_FILE"

# setup.py reads STRATA_API_KEY directly.
export STRATA_API_KEY


# ------------------------------------------------------------
# Clone Strata
# ------------------------------------------------------------

if [[ ! -d "${STRATA_DIR}/.git" ]]; then

    info "Cloning Strata"

    git clone \
        https://github.com/Niko1221/Strata.git \
        "$STRATA_DIR"

fi

cd "$STRATA_DIR"


# ------------------------------------------------------------
# Pin exact Strata source commit
# ------------------------------------------------------------

CURRENT_COMMIT="$(git rev-parse HEAD 2>/dev/null || true)"

if [[ "$CURRENT_COMMIT" != "$STRATA_COMMIT" ]]; then

    info "Switching Strata to fixed commit:"
    echo "    ${STRATA_COMMIT}"

    git fetch origin "$STRATA_COMMIT" || git fetch origin

    git checkout --detach "$STRATA_COMMIT"
fi

ACTUAL_COMMIT="$(git rev-parse HEAD)"

[[ "$ACTUAL_COMMIT" == "$STRATA_COMMIT" ]] \
    || die "Wrong Strata commit: ${ACTUAL_COMMIT}"

info "Strata commit verified:"
echo "    ${ACTUAL_COMMIT}"


# ------------------------------------------------------------
# Download our prebuilt engine
# ------------------------------------------------------------

mkdir -p "$CACHE_DIR"

NEED_DOWNLOAD=1

if [[ -f "$PREBUILT_ZIP" ]]; then

    HAVE_SHA="$(
        sha256sum "$PREBUILT_ZIP" \
        | awk '{print $1}'
    )"

    if [[ "$HAVE_SHA" == "$PREBUILT_SHA256" ]]; then
        NEED_DOWNLOAD=0
        info "Cached prebuilt archive verified"
    else
        warn "Cached prebuilt checksum mismatch; downloading again"
        rm -f "$PREBUILT_ZIP"
    fi
fi


if (( NEED_DOWNLOAD )); then

    info "Downloading RTX 3090 prebuilt engine"

    curl \
        -fL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 30 \
        "$PREBUILT_URL" \
        -o "$PREBUILT_ZIP"
fi


# ------------------------------------------------------------
# SHA256 verification
# ------------------------------------------------------------

info "Verifying prebuilt SHA256"

echo "${PREBUILT_SHA256}  ${PREBUILT_ZIP}" \
    | sha256sum -c -

info "Prebuilt archive verified"


# ------------------------------------------------------------
# Install prebuilt engine
# ------------------------------------------------------------

ENGINE_OK=0

if [[ -f "${ENGINE_DIR}/BUILD.json" ]] \
    && [[ -x "${ENGINE_DIR}/strata" ]] \
    && [[ -x "${ENGINE_DIR}/strata-vision" ]]
then

    if python3 - "$ENGINE_DIR/BUILD.json" <<'PY'
import json
import sys

p = sys.argv[1]

try:
    d = json.load(open(p))
except Exception:
    raise SystemExit(1)

ok = (
    d.get("source") == "prebuilt"
    and d.get("version") == "0.1.39"
    and 86 in d.get("archs", [])
    and d.get("vision") == "gpu"
)

raise SystemExit(0 if ok else 1)
PY
    then
        ENGINE_OK=1
    fi
fi


if (( ENGINE_OK )); then

    info "Correct prebuilt engine already installed"

else

    info "Installing prebuilt engine"

    rm -rf "$ENGINE_DIR"
    mkdir -p "$ENGINE_DIR"

    unzip -q \
        "$PREBUILT_ZIP" \
        -d "$ENGINE_DIR"

    chmod 700 \
        "${ENGINE_DIR}/strata" \
        "${ENGINE_DIR}/strata-vision"

fi


# ------------------------------------------------------------
# Verify BUILD.json
# ------------------------------------------------------------

info "Checking prebuilt metadata"

python3 - "$ENGINE_DIR/BUILD.json" <<'PY'
import json
import sys

p = sys.argv[1]

with open(p) as f:
    d = json.load(f)

required = {
    "source": "prebuilt",
    "version": "0.1.39",
    "vision": "gpu",
}

for key, expected in required.items():
    actual = d.get(key)

    if actual != expected:
        raise SystemExit(
            f"{key}: expected {expected!r}, got {actual!r}"
        )

if 86 not in d.get("archs", []):
    raise SystemExit(
        f"sm_86 missing from archs: {d.get('archs')}"
    )

print("    source :", d.get("source"))
print("    version:", d.get("version"))
print("    archs  :", d.get("archs"))
print("    vision :", d.get("vision"))
print("    src    :", d.get("src"))
print("    vsrc   :", d.get("vision_src"))
PY


# ------------------------------------------------------------
# Run Strata setup
#
# engine/ already contains our verified prebuilt.
# setup.py should therefore skip compiling strata/strata-vision.
# ------------------------------------------------------------

info "Running Strata model setup"
echo
echo "    Model   : IQ3_S"
echo "    Context : ${CONTEXT}"
echo "    Vision  : GPU"
echo "    Host    : 0.0.0.0"
echo "    Port    : ${PORT}"
echo

./setup.sh \
    --yes \
    --family qwen \
    --model IQ3_S \
    --context "$CONTEXT" \
    --vision gpu \
    --host 0.0.0.0 \
    --port "$PORT" \
    --prebuilt "${PREBUILT_BASE}/" \
    --no-start


# ------------------------------------------------------------
# Sanity check
# ------------------------------------------------------------

[[ -f "$CONFIG" ]] \
    || die "Setup finished but ${CONFIG} was not created"

[[ -f "$RUN_SCRIPT" ]] \
    || die "Setup finished but ${RUN_SCRIPT} was not created"


# ------------------------------------------------------------
# Apply our calibrated RTX 3090 / EPYC settings
# ------------------------------------------------------------

info "Applying calibrated tuning"

python3 - "$CONFIG" "$PORT" <<'PY'
import json
import sys

path = sys.argv[1]
port = int(sys.argv[2])

with open(path) as f:
    cfg = json.load(f)

args = cfg.setdefault("args", [])

settings = {
    "--pcie-frac": "0.00",
    "--spec-min-p": "0.70",
    "--pool-workers": "64",
}

for option, value in settings.items():

    while args.count(option) > 1:
        i = len(args) - 1 - args[::-1].index(option)

        del args[i:i + 2]

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


with open(path, "w") as f:
    json.dump(cfg, f, indent=2)


print("    --pcie-frac     0.00")
print("    --spec-min-p    0.70")
print("    --pool-workers  64")
PY


# ------------------------------------------------------------
# Verify API/network config
# ------------------------------------------------------------

python3 - "$CONFIG" <<'PY'
import json
import sys

cfg = json.load(open(sys.argv[1]))

if cfg.get("host") != "0.0.0.0":
    raise SystemExit("host is not 0.0.0.0")

if int(cfg.get("port", 0)) != 8000:
    raise SystemExit("port is not 8000")

if not cfg.get("api_key"):
    raise SystemExit("API key was not saved into Strata config")

print("[+] Network/API configuration verified")
PY


# ------------------------------------------------------------
# Don't start a duplicate server
# ------------------------------------------------------------

if curl \
    -fsS \
    --connect-timeout 2 \
    -H "Authorization: Bearer ${STRATA_API_KEY}" \
    "http://127.0.0.1:${PORT}/v1/models" \
    >/dev/null 2>&1
then

    info "Strata is already running on port ${PORT}"

else

    info "Starting Strata"

    cd "$STRATA_DIR"

    nohup env \
        STRATA_ARENA_PIN_GIB=8 \
        ./run-iq3_s.sh \
        > "$LOG_FILE" 2>&1 &

    STRATA_PID="$!"

    printf '%s\n' "$STRATA_PID" > "$PID_FILE"

    info "PID: ${STRATA_PID}"

fi


# ------------------------------------------------------------
# Helper environment file
# ------------------------------------------------------------

cat > "${WORKSPACE}/strata-env.sh" <<EOF
export STRATA_API_KEY="\$(cat ${KEY_FILE})"
export OPENAI_API_KEY="\$STRATA_API_KEY"

export OPENAI_HOST="http://127.0.0.1:${PORT}"
export OPENAI_BASE_PATH="v1/chat/completions"

export GOOSE_PROVIDER="openai"
export GOOSE_MODEL="qwen3.8-flash-next-iq3_s"
export GOOSE_CONTEXT_LIMIT=32768
EOF

chmod 600 "${WORKSPACE}/strata-env.sh"


# ------------------------------------------------------------
# Finish
# ------------------------------------------------------------

echo
echo "=============================================="
echo " Bootstrap complete"
echo "=============================================="
echo
echo "Strata commit:"
echo "  ${STRATA_COMMIT}"
echo
echo "Engine:"
echo "  custom RTX 3090 / sm_86 prebuilt"
echo
echo "Model:"
echo "  qwen3.8-flash-next-iq3_s"
echo
echo "Vision:"
echo "  GPU"
echo
echo "Context:"
echo "  ${CONTEXT}"
echo
echo "Port:"
echo "  ${PORT}"
echo
echo "Tuning:"
echo "  --pcie-frac 0.00"
echo "  --spec-min-p 0.70"
echo "  --pool-workers 64"
echo "  STRATA_ARENA_PIN_GIB=8"
echo
echo "API key:"
echo "  ${KEY_FILE}"
echo
echo "Show API key:"
echo "  cat ${KEY_FILE}"
echo
echo "Startup log:"
echo "  tail -f ${LOG_FILE}"
echo
echo "Check API after startup:"
echo "  curl -s http://127.0.0.1:${PORT}/v1/models \\"
echo '    -H "Authorization: Bearer $(cat /workspace/.strata-api-key)"'
echo
echo "Load helper environment:"
echo "  source /workspace/strata-env.sh"
echo
echo "NOTE:"
echo "  IQ3_S model files still need to be downloaded on a fresh workspace."
echo "  The Strata engine and strata-vision compilation have been eliminated."
echo
