#!/usr/bin/env bash
set -euo pipefail

: "${STRATA_API_KEY:?Set STRATA_API_KEY first}"

ROOT=/workspace/Strata
CFG="$ROOT/strata-iq3_s.json"

if [[ ! -d "$ROOT/.git" ]]; then
  cd /workspace
  git clone https://github.com/Niko1221/Strata.git
fi

cd "$ROOT"

./setup.sh --yes \
  --family qwen \
  --model IQ3_S \
  --context 131072 \
  --vision gpu \
  --host 0.0.0.0 \
  --port 8000 \
  --api-key "$STRATA_API_KEY" \
  --no-start

python3 - <<'PY'
import json

p = "/workspace/Strata/strata-iq3_s.json"

with open(p) as f:
    d = json.load(f)

args = d["args"]

for k, v in {
    "--pcie-frac": "0.00",
    "--spec-min-p": "0.70",
    "--pool-workers": "64",
}.items():
    if k in args:
        args[args.index(k) + 1] = v
    else:
        args += [k, v]

with open(p, "w") as f:
    json.dump(d, f, indent=2)
PY

export STRATA_ARENA_PIN_GIB=8

nohup ./run-iq3_s.sh > strata-server.out 2>&1 &
echo $! > strata-server.pid

echo
echo "Strata is starting."
echo "Log:"
echo "  tail -f /workspace/Strata/strata-server.out"
