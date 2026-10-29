#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/serve.env"
[[ ! -f "$HERE/serve.env.local" ]] || source "$HERE/serve.env.local"
MODEL_ROOT="${G05_WORKSPACE:-$HOME/workspace/lemo-models}"
CK="$MODEL_ROOT/g05/lemo4_pick_lora"
CHECKPOINT="${G05_CHECKPOINT:-$CK/checkpoints/${1:-step_20000}.pt}"
TOKENIZER="${G05_TOKENIZER:-$CK/action_tokenizer.pt}"
PROCESSOR="${G05_PROCESSOR:-$MODEL_ROOT/qwen3_5_2b_base_processor}"
PY="${EFMNODE_PYTHON:-$CODE_ROOT/.venv/bin/python}"
cd "$CODE_ROOT"
export PYTHONPATH="$CODE_ROOT/src"
export A1Z_WORKSPACE="$MODEL_ROOT"
exec "$PY" scripts/serve_policy.py \
  --ckpt_path "$CHECKPOINT" --host 0.0.0.0 --port "${SERVE_PORT:-8765}" \
  --device "${DEVICE:-cuda}" --action_steps 16 \
  eval_embodiment="${EMBODIMENT:-galaxea_a1z}" \
  model.model_arch.hf_processor_path="$PROCESSOR" \
  model.processor.tokenizer_params.pretrained_model_name_or_path="$PROCESSOR" \
  tokenizer.vq_config.ckpt_dir="$TOKENIZER" \
  model.tokenizer.vq_config.ckpt_dir="$TOKENIZER" \
  model.model_arch.AT_CONFIG.ckpt_dir="$TOKENIZER"
