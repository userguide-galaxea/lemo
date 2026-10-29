#!/usr/bin/env bash
# Install one inference backend without requiring Conda; never starts a robot.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
trap 'echo "[FATAL] Environment setup/check failed at line $LINENO. Installation is NOT complete. Fix the error and rerun server_setup.sh --backend ${BACKEND:-g05}." >&2' ERR
fail() { echo "[FATAL] $*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage:
  bash server_setup.sh --backend g05
  bash server_setup.sh --backend lerobot
Options:
  --skip-system     Skip apt dependencies (must already be installed)
  --check           Check existing backend environment only; no installation
  -h, --help        Show help
Installs Python environment and dependencies only. No model files required.
Does not create/change serve.env.local or start any server.
Configure models in deploy/serve.env.local; start with deploy/start_serve.sh.
Requires Linux x86_64, system Python 3, and an installed NVIDIA driver.
HELP
}
BACKEND= SYSTEM=1 CHECK=0
while (($#)); do
  case "$1" in
    --backend)
      (($# >= 2)) || fail 'Missing value for --backend'
      BACKEND=$2; shift 2;;
    --skip-system) SYSTEM=0; shift;; --check) CHECK=1; shift;;
    -h|--help) usage; exit 0;; *) fail "Unknown option: $1 (see --help)";;
  esac
done
[[ "$BACKEND" = g05 || "$BACKEND" = lerobot ]] || fail 'Choose --backend g05 or lerobot'
command -v python3 >/dev/null || fail 'Install system Python 3 first'
if [[ "$BACKEND" = g05 ]]; then ENV_DIR="$ROOT/.venv"; else ENV_DIR="$ROOT/.venv-lerobot"; fi
verify_environment() {
  local interpreter="$ENV_DIR/bin/python"
  [[ -x "$interpreter" ]] || fail "Environment not installed: $ENV_DIR"
  "$interpreter" -c 'import sys, torch; print("Python:",sys.executable); print("PyTorch:",torch.__version__,"CUDA:",torch.version.cuda); assert torch.cuda.is_available(), "CUDA unavailable"'
  if [[ "$BACKEND" = lerobot ]]; then
    "$interpreter" -c 'import lerobot, msgpack, websockets, cv2'
  else
    "$interpreter" -c 'import hydra, transformers, msgpack, websockets'
  fi
  # Import the actual entrypoint without loading user model weights or opening a port.
  local entrypoint=serve_policy.py
  [[ "$BACKEND" != lerobot ]] || entrypoint=serve_lerobot.py
  PYTHONPATH="$ROOT/src" "$interpreter" "$ROOT/scripts/$entrypoint" --help >/dev/null
}
if ((CHECK)); then
  verify_environment
  echo 'Environment checks passed. No model loaded or configuration changed.'
  exit 0
fi
[[ $(uname -s) = Linux && $(uname -m) = x86_64 ]] || fail 'Requires Linux x86_64 GPU server'
((EUID != 0)) || fail 'Run as a normal user; sudo is used only for apt'
command -v nvidia-smi >/dev/null || fail 'Install NVIDIA driver first'
nvidia-smi --query-gpu=name,driver_version --format=csv
if ((SYSTEM)); then
  command -v apt-get >/dev/null || fail 'Install cmake/build-essential/python3-venv manually and use --skip-system'
  sudo apt-get update
  sudo apt-get install -y cmake build-essential python3-venv
fi
for tool in cmake g++ ss; do command -v "$tool" >/dev/null || fail "Missing required tool: $tool"; done
# Use a private bootstrap environment rather than modifying system/Conda Python.
if command -v uv >/dev/null; then UV=$(command -v uv); else
  python3 -m venv "$ROOT/.setup-venv"
  "$ROOT/.setup-venv/bin/python" -m pip install uv
  UV="$ROOT/.setup-venv/bin/uv"
fi
cd "$ROOT"
if [[ "$BACKEND" = g05 ]]; then
  ENV_DIR="$ROOT/.venv"
  echo "Installing G0.5 dependencies; downloads/builds may take several minutes. Wait for Environment ready."
  UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-120}" UV_PROJECT_ENVIRONMENT="$ENV_DIR" "$UV" sync --locked --python 3.10.16 --index-strategy unsafe-best-match
else
  ENV_DIR="$ROOT/.venv-lerobot"
  [[ -x "$ENV_DIR/bin/python" ]] || "$UV" venv "$ENV_DIR" --python 3.10.16
  "$UV" pip install --python "$ENV_DIR/bin/python" --index-url https://download.pytorch.org/whl/cu128 \
    'torch==2.7.1' 'torchvision==0.22.1' 'torchaudio==2.7.1'
  "$UV" pip install --python "$ENV_DIR/bin/python" \
    'lerobot==0.4.2' msgpack websockets opencv-python-headless \
    'transformers==4.52.4' 'huggingface-hub>=0.34.2,<0.36.0' num2words
fi
verify_environment
echo "Environment ready: $ENV_DIR"
echo 'No model loaded, configuration changed, or server started.'
echo 'Next: configure deploy/serve.env.local, then run bash deploy/start_serve.sh.'
