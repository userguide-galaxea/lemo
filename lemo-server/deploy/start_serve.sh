#!/bin/bash
# GalaxeaVLA A1Z 推理服务启动脚本 —— 配置项全部在同目录 serve.env
# 用法: bash deploy/start_serve.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$HERE/serve.env"
# 本机覆盖:serve.env.local(gitignore 不入库),字段同 serve.env,逐项覆盖
if [ -f "$HERE/serve.env.local" ]; then
  source "$HERE/serve.env.local"
fi

WS="${G05_WORKSPACE:-$HOME/workspace/lemo-models}"
PORT="${SERVE_PORT:-8765}"
MODEL_TYPE="${MODEL_TYPE:-g05}"

if [ "$MODEL_TYPE" = "lerobot" ]; then
  # ── LeRobot 策略(DP/ACT/pi0 等)──────────────────────────────
  # HF 端点可配(内网不通 huggingface.co 时设 HF_ENDPOINT 镜像,写进 serve.env.local)
  [ -n "${HF_ENDPOINT:-}" ] && export HF_ENDPOINT
  PY="${LEROBOT_PYTHON:-$CODE_ROOT/.venv-lerobot/bin/python}"
  MAPPING="${LEROBOT_MAPPING:-$CODE_ROOT/deploy/lerobot_a1z_mapping.json}"
  [ -n "$LEROBOT_POLICY_PATH" ] || { echo "[FATAL] serve.env 未配 LEROBOT_POLICY_PATH"; exit 1; }
  [ -f "$LEROBOT_POLICY_PATH/config.json" ] || { echo "[FATAL] lerobot ckpt 无效(缺 config.json): $LEROBOT_POLICY_PATH"; exit 1; }
  [ -f "$MAPPING" ] || { echo "[FATAL] 映射文件不存在: $MAPPING"; exit 1; }
  if [ ! -f "$LEROBOT_POLICY_PATH/policy_preprocessor.json" ] && [ -z "${LEROBOT_STATS_PATH:-}" ]; then
    echo "[FATAL] ckpt 无内嵌 processor,必须配 LEROBOT_STATS_PATH(数据集 stats.json)"; exit 1
  fi
  [ -x "$PY" ] || { echo "[FATAL] python 不存在: $PY(检查 serve.env 的 LEROBOT_PYTHON)"; exit 1; }
  if ss -tln 2>/dev/null | grep -q ":$PORT "; then
    echo "[FATAL] 端口 $PORT 已被占用:"; ss -tlnp 2>/dev/null | grep ":$PORT "; exit 1
  fi
  cd "$CODE_ROOT"
  export PYTHONPATH="$CODE_ROOT/src"
  echo "[serve] lerobot policy=$LEROBOT_POLICY_PATH port=$PORT"
  extra_args=()
  [[ -z "${LEROBOT_STATS_PATH:-}" ]] || extra_args+=(--stats_path "$LEROBOT_STATS_PATH")
  [[ -z "${LEROBOT_DEFAULT_TASK:-}" ]] || extra_args+=(--default_task "$LEROBOT_DEFAULT_TASK")
  exec "$PY" scripts/serve_lerobot.py \
    --policy_path "$LEROBOT_POLICY_PATH" \
    --mapping "$MAPPING" \
    "${extra_args[@]}" \
    --host 0.0.0.0 --port "$PORT" --device "$DEVICE" --action_steps "$ACTION_STEPS"
fi

[[ "$MODEL_TYPE" = g05 ]] || { echo "[FATAL] Unknown MODEL_TYPE: $MODEL_TYPE"; exit 1; }
CK="$WS/g05/${MODEL_RUN:-}"
CHECKPOINT="${G05_CHECKPOINT:-$CK/checkpoints/${MODEL_STEP:-}.pt}"
TOKENIZER="${G05_TOKENIZER:-$CK/action_tokenizer.pt}"
PROCESSOR="${G05_PROCESSOR:-$WS/qwen3_5_2b_base_processor}"
PY="${EFMNODE_PYTHON:-$CODE_ROOT/.venv/bin/python}"

# ── 启动前自检:缺文件/端口被占直接报错退出,不带病启动 ──────────────
for f in "$CHECKPOINT" "$TOKENIZER" \
         "$PROCESSOR"; do
  [ -e "$f" ] || { echo "[FATAL] 模型文件不存在: $f(检查 serve.env 的 G05_WORKSPACE/MODEL_RUN/MODEL_STEP)"; exit 1; }
done
[ -x "$PY" ] || { echo "[FATAL] python 不存在: $PY(检查 serve.env 的 EFMNODE_PYTHON)"; exit 1; }
if ss -tln 2>/dev/null | grep -q ":$PORT "; then
  echo "[FATAL] 端口 $PORT 已被占用:"; ss -tlnp 2>/dev/null | grep ":$PORT "; exit 1
fi

cd "$CODE_ROOT"
export PYTHONPATH="$CODE_ROOT/src"
export A1Z_WORKSPACE="$WS"
echo "[serve] ckpt=$CHECKPOINT port=$PORT embodiment=$EMBODIMENT"
exec "$PY" scripts/serve_policy.py \
  --ckpt_path "$CHECKPOINT" \
  --host 0.0.0.0 --port "$PORT" --device "$DEVICE" --action_steps "$ACTION_STEPS" \
  eval_embodiment="$EMBODIMENT" \
  model.model_arch.hf_processor_path="$PROCESSOR" \
  model.processor.tokenizer_params.pretrained_model_name_or_path="$PROCESSOR" \
  tokenizer.vq_config.ckpt_dir="$TOKENIZER" \
  model.tokenizer.vq_config.ckpt_dir="$TOKENIZER" \
  model.model_arch.AT_CONFIG.ckpt_dir="$TOKENIZER"
