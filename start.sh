#!/usr/bin/env bash
set -Eeuo pipefail

MODEL_REPO="${MODEL_REPO:-prithivMLmods/Qwen3-VL-8B-Heretic-Stable-GGUF}"
MODEL_FILE="${MODEL_FILE:-Qwen3-VL-8B-Heretic-Stable.Q4_K_M.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-Qwen3-VL-8B-Heretic-Stable.mmproj-bf16.gguf}"

MODEL_DIR="${MODEL_DIR:-/models}"

mkdir -p "${MODEL_DIR}" /app/backend/data /var/log/supervisor

download_file() {
    local filename="$1"
    local target="${MODEL_DIR}/${filename}"
    local url="https://huggingface.co/${MODEL_REPO}/resolve/main/${filename}"

    if [ -s "${target}" ]; then
        echo "Файл уже существует: ${target}"
        return
    fi

    echo "Загрузка ${filename}"
    wget \
        --continue \
        --progress=dot:giga \
        --output-document="${target}" \
        "${url}"
}

download_file "${MODEL_FILE}"
download_file "${MMPROJ_FILE}"

exec /usr/bin/supervisord \
    --nodaemon \
    --configuration /etc/supervisor/supervisord.conf
