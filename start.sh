#!/usr/bin/env bash
set -e

MODE="${1:-vision}"

MODELS_DIR="/models"
CONF_TEMPLATE="/etc/supervisor/conf.d/gpu-game.conf"
CONF_ACTIVE="/tmp/gpu-game.active.conf"

mkdir -p "$MODELS_DIR"

echo "=== GPU Game launcher ==="
echo "Mode: $MODE"
echo "Models dir: $MODELS_DIR"

download_if_missing() {
  local path="$1"
  local url="$2"

  if [ -f "$path" ]; then
    echo "Model already exists: $path"
  else
    echo "Downloading: $path"
    wget -c -O "$path" "$url"
  fi
}

case "$MODE" in
  vision)
    MODEL_PATH="$MODELS_DIR/Qwen3-VL-8B-Heretic-Stable.Q4_K_M.gguf"
    MMPROJ_PATH="$MODELS_DIR/Qwen3-VL-8B-Heretic-Stable.mmproj-bf16.gguf"

    download_if_missing "$MODEL_PATH" \
      "https://huggingface.co/prithivMLmods/Qwen3-VL-8B-Heretic-Stable-GGUF/resolve/main/Qwen3-VL-8B-Heretic-Stable.Q4_K_M.gguf?download=true"

    download_if_missing "$MMPROJ_PATH" \
      "https://huggingface.co/prithivMLmods/Qwen3-VL-8B-Heretic-Stable-GGUF/resolve/main/Qwen3-VL-8B-Heretic-Stable.mmproj-bf16.gguf?download=true"

    LLAMA_COMMAND="/app/llama-server --model $MODEL_PATH --mmproj $MMPROJ_PATH --host 0.0.0.0 --port 10000 --ctx-size 32768 --n-gpu-layers 99 --flash-attn on --parallel 1 --jinja"
    ;;

  rocinante)
    MODEL_PATH="$MODELS_DIR/Rocinante-12B-v2i-Q4_K_M.gguf"

    download_if_missing "$MODEL_PATH" \
      "https://huggingface.co/TheDrummer/UnslopNemo-12B-v4-GGUF/resolve/main/Rocinante-12B-v2i-Q4_K_M.gguf?download=true"

    LLAMA_COMMAND="/app/llama-server --model $MODEL_PATH --host 0.0.0.0 --port 10000 --ctx-size 32768 --n-gpu-layers 99 --flash-attn on --parallel 1 --jinja"
    ;;

  magnum)
    MODEL_PATH="$MODELS_DIR/magnum-v4-12b-Q5_K_M.gguf"

    download_if_missing "$MODEL_PATH" \
      "https://huggingface.co/bartowski/magnum-v4-12b-GGUF/resolve/main/magnum-v4-12b-Q5_K_M.gguf?download=true"

    LLAMA_COMMAND="/app/llama-server --model $MODEL_PATH --host 0.0.0.0 --port 10000 --ctx-size 32768 --n-gpu-layers 99 --flash-attn on --parallel 1 --jinja"
    ;;

  *)
    echo "Unknown mode: $MODE"
    echo "Available modes: vision, rocinante, magnum"
    exit 1
    ;;
esac

echo "Selected model command:"
echo "$LLAMA_COMMAND"

export LLAMA_COMMAND

envsubst < "$CONF_TEMPLATE" > "$CONF_ACTIVE"

echo "Starting supervisord..."
exec /usr/bin/supervisord --nodaemon --configuration "$CONF_ACTIVE"
