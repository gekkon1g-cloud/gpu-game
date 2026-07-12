#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="/opt/gpu-game"
DATA_DIR="/data/gpu-game"

MODELS_DIR="/models"
LLM_DIR="$MODELS_DIR/llm"
VISION_DIR="$MODELS_DIR/vision"
TEST_DIR="$MODELS_DIR/test"

COMFY_CHECKPOINT_DIR="/opt/ComfyUI/models/checkpoints"

ACTIVE_SUPERVISOR_CONF="/tmp/gpu-game.supervisord.conf"
ACTIVE_CADDYFILE="/tmp/gpu-game.Caddyfile"

RUNTIME_ENV="$DATA_DIR/runtime.env"
LINKS_FILE="$DATA_DIR/links.txt"
PASSWORD_FILE="$DATA_DIR/comfy-password.txt"
WEBUI_SECRET_FILE="$PROJECT_DIR/.webui_secret_key"

SUPERVISOR_TEMPLATE="/etc/supervisor/conf.d/gpu-game.conf"
CADDY_TEMPLATE="$PROJECT_DIR/Caddyfile.template"

ROCINANTE_FILE="$LLM_DIR/Rocinante-12B-v2i-Q4_K_M.gguf"

VISION_FILE="$VISION_DIR/Qwen3-VL-8B-Heretic-Stable.Q4_K_M.gguf"
VISION_MMPROJ_FILE="$VISION_DIR/Qwen3-VL-8B-Heretic-Stable.mmproj-bf16.gguf"

mkdir -p \
    "$DATA_DIR" \
    "$LLM_DIR" \
    "$VISION_DIR" \
    "$TEST_DIR" \
    "$COMFY_CHECKPOINT_DIR" \
    /var/log/gpu-game

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf 'Предупреждение: %s\n' "$*" >&2
}

die() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

require_file() {
    local file_path="$1"
    local description="$2"

    if [[ ! -s "$file_path" ]]; then
        echo
        echo "Не найден файл: $description"
        echo "Ожидаемый путь:"
        echo "  $file_path"
        echo
        echo "Модели в этом образе устанавливаются вручную."
        echo "Сначала загрузи необходимый файл, затем повтори запуск."
        echo
        exit 1
    fi
}

detect_public_ip() {
    local ip=""

    ip="${GPU_PUBLIC_IP:-}"

    if [[ -z "$ip" ]]; then
        ip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
    fi

    if [[ -z "$ip" ]]; then
        ip="$(curl -4fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
    fi

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
        die "Не удалось определить публичный IP. Запусти так: gpu-start MODE IP"

    printf '%s\n' "$ip"
}

make_webui_secret() {
    if [[ ! -s "$WEBUI_SECRET_FILE" ]]; then
        openssl rand -hex 32 > "$WEBUI_SECRET_FILE"
        chmod 600 "$WEBUI_SECRET_FILE"
    fi
}

make_comfy_password() {
    if [[ ! -s "$PASSWORD_FILE" ]]; then
        openssl rand -base64 18 |
            tr -d '/+=' |
            cut -c1-20 > "$PASSWORD_FILE"

        chmod 600 "$PASSWORD_FILE"
    fi

    COMFY_PASSWORD="$(cat "$PASSWORD_FILE")"
    COMFY_PASSWORD_HASH="$(
        /usr/local/bin/caddy hash-password \
            --plaintext "$COMFY_PASSWORD"
    )"

    export COMFY_PASSWORD
    export COMFY_PASSWORD_HASH
}

stop_existing() {
    if [[ -f /var/run/gpu-game-supervisord.pid ]]; then
        local pid

        pid="$(
            cat /var/run/gpu-game-supervisord.pid \
                2>/dev/null || true
        )"

        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log "Остановка предыдущего режима..."

            kill "$pid" 2>/dev/null || true

            for _ in $(seq 1 30); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done

            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    pkill -f "/app/llama-server.*--port 10000" \
        2>/dev/null || true

    pkill -f "/app/llama-server.*--port 10001" \
        2>/dev/null || true

    pkill -f "/app/llama-server.*--port 10100" \
        2>/dev/null || true

    pkill -f "/opt/ComfyUI/venv/bin/python.*main.py" \
        2>/dev/null || true

    pkill -f "/opt/open-webui/venv/bin/open-webui" \
        2>/dev/null || true

    pkill -f "caddy run --config $ACTIVE_CADDYFILE" \
        2>/dev/null || true

    rm -f \
        /var/run/gpu-game-supervisord.pid \
        /var/run/gpu-game-supervisor.sock
}

check_mode_files() {
    local mode="$1"

    case "$mode" in
        webui|all)
            require_file \
                "$ROCINANTE_FILE" \
                "основная модель Rocinante"

            require_file \
                "$VISION_FILE" \
                "мультимодальная модель Qwen3-VL"

            require_file \
                "$VISION_MMPROJ_FILE" \
                "проектор mmproj модели Qwen3-VL"
            ;;

        comfy)
            if ! find "$COMFY_CHECKPOINT_DIR" \
                -maxdepth 1 \
                -type f \
                \( -iname '*.safetensors' -o -iname '*.ckpt' \) \
                -print -quit |
                grep -q .; then

                warn "В каталоге ComfyUI пока нет checkpoint-моделей."
                warn "ComfyUI запустится, но генерация будет недоступна до ручной загрузки модели."
                warn "Каталог: $COMFY_CHECKPOINT_DIR"
            fi
            ;;

        test)
            ;;

        *)
            die "Неизвестный режим: $mode"
            ;;
    esac
}

build_caddy_config() {
    local mode="$1"
    local public_ip="$2"
    local ip_name="${public_ip//./-}"

    CHAT_HOST="chat.${ip_name}.sslip.io"
    COMFY_HOST="comfy.${ip_name}.sslip.io"

    CHAT_BLOCK=""
    COMFY_BLOCK=""

    case "$mode" in
        webui)
            CHAT_BLOCK="${CHAT_HOST} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000
}"
            ;;

        comfy)
            COMFY_BLOCK="${COMFY_HOST} {
    encode zstd gzip

    basic_auth {
        alex ${COMFY_PASSWORD_HASH}
    }

    reverse_proxy 127.0.0.1:8188
}"
            ;;

        all|test)
            CHAT_BLOCK="${CHAT_HOST} {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3000
}"

            COMFY_BLOCK="${COMFY_HOST} {
    encode zstd gzip

    basic_auth {
        alex ${COMFY_PASSWORD_HASH}
    }

    reverse_proxy 127.0.0.1:8188
}"
            ;;
    esac

    export CHAT_BLOCK
    export COMFY_BLOCK

    envsubst \
        '${CHAT_BLOCK} ${COMFY_BLOCK}' \
        < "$CADDY_TEMPLATE" \
        > "$ACTIVE_CADDYFILE"

    /usr/local/bin/caddy validate \
        --config "$ACTIVE_CADDYFILE" \
        --adapter caddyfile
}

prepare_mode() {
    local mode="$1"

    START_ROCINANTE="false"
    START_VISION="false"
    START_WEBUI="false"
    START_COMFY="false"
    START_CADDY="true"

    case "$mode" in
        webui)
            START_ROCINANTE="true"
            START_VISION="true"
            START_WEBUI="true"
            ;;

        comfy)
            START_COMFY="true"
            ;;

        all)
            START_ROCINANTE="true"
            START_VISION="true"
            START_WEBUI="true"
            START_COMFY="true"
            ;;

        test)
            START_WEBUI="true"
            START_COMFY="true"
            ;;

        *)
            die "Неизвестный режим: $mode"
            ;;
    esac

    export START_ROCINANTE
    export START_VISION
    export START_WEBUI
    export START_COMFY
    export START_CADDY
}

build_supervisor_config() {
    export ROCINANTE_FILE
    export VISION_FILE
    export VISION_MMPROJ_FILE
    export ACTIVE_CADDYFILE
    export WEBUI_SECRET_FILE

    envsubst \
        '${ROCINANTE_FILE} ${VISION_FILE} ${VISION_MMPROJ_FILE} ${ACTIVE_CADDYFILE} ${WEBUI_SECRET_FILE}' \
        < "$SUPERVISOR_TEMPLATE" \
        > "$ACTIVE_SUPERVISOR_CONF"
}

write_runtime_env() {
    local mode="$1"
    local public_ip="$2"

    cat > "$RUNTIME_ENV" <<EOF
GPU_MODE=$mode
GPU_PUBLIC_IP=$public_ip
CHAT_HOST=$CHAT_HOST
COMFY_HOST=$COMFY_HOST
EOF

    chmod 600 "$RUNTIME_ENV"
}

write_links() {
    local mode="$1"

    : > "$LINKS_FILE"

    case "$mode" in
        webui)
            printf \
                'Open WebUI: https://%s\n' \
                "$CHAT_HOST" \
                >> "$LINKS_FILE"
            ;;

        comfy)
            printf \
                'ComfyUI: https://%s\n' \
                "$COMFY_HOST" \
                >> "$LINKS_FILE"

            printf \
                'Логин: alex\n' \
                >> "$LINKS_FILE"

            printf \
                'Пароль: %s\n' \
                "$COMFY_PASSWORD" \
                >> "$LINKS_FILE"
            ;;

        all|test)
            printf \
                'Open WebUI: https://%s\n' \
                "$CHAT_HOST" \
                >> "$LINKS_FILE"

            printf \
                'ComfyUI: https://%s\n' \
                "$COMFY_HOST" \
                >> "$LINKS_FILE"

            printf \
                'Логин ComfyUI: alex\n' \
                >> "$LINKS_FILE"

            printf \
                'Пароль ComfyUI: %s\n' \
                "$COMFY_PASSWORD" \
                >> "$LINKS_FILE"
            ;;
    esac
}

start_services() {
    log "Запуск Supervisor..."

    /usr/bin/supervisord \
        -c "$ACTIVE_SUPERVISOR_CONF"

    sleep 5

    gpu_status

    echo

    gpu_links
}

gpu_start() {
    local mode="${1:-}"
    local explicit_ip="${2:-}"

    case "$mode" in
        webui|comfy|all|test)
            ;;
        *)
            show_help
            exit 1
            ;;
    esac

    if [[ -n "$explicit_ip" ]]; then
        export GPU_PUBLIC_IP="$explicit_ip"
    fi

    stop_existing
    make_webui_secret
    make_comfy_password

    local public_ip
    public_ip="$(detect_public_ip)"

    log "Режим: $mode"
    log "Публичный IP: $public_ip"

    check_mode_files "$mode"
    prepare_mode "$mode"
    build_caddy_config "$mode" "$public_ip"
    build_supervisor_config
    write_runtime_env "$mode" "$public_ip"
    write_links "$mode"
    start_services
}

gpu_stop() {
    stop_existing
    log "Все сервисы GPU Game остановлены."
}

gpu_status() {
    if [[ ! -S /var/run/gpu-game-supervisor.sock ]]; then
        echo "GPU Game не запущен."
        return 1
    fi

    if [[ -s "$RUNTIME_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$RUNTIME_ENV"

        echo "Режим: ${GPU_MODE:-неизвестно}"
        echo
    fi

    supervisorctl \
        -c "$ACTIVE_SUPERVISOR_CONF" \
        status || true

    echo
    echo "Примечание:"
    echo "Неактивные для выбранного режима службы могут отображаться как RUNNING,"
    echo "поскольку внутри них выполняется только sleep infinity."
    echo

    nvidia-smi \
        --query-gpu=name,memory.total,memory.used,utilization.gpu \
        --format=csv,noheader \
        2>/dev/null || true
}

gpu_logs() {
    local service="${1:-}"

    if [[ -n "$service" ]]; then
        local logfile="/var/log/gpu-game/${service}.log"

        [[ -f "$logfile" ]] || \
            die "Файл журнала не найден: $logfile"

        tail -f "$logfile"
        return
    fi

    echo "Доступные логи:"

    find /var/log/gpu-game \
        -maxdepth 1 \
        -type f \
        -printf '  %f\n' \
        2>/dev/null |
        sort

    echo
    echo "Примеры:"
    echo "  gpu-logs rocinante"
    echo "  gpu-logs vision"
    echo "  gpu-logs open-webui"
    echo "  gpu-logs comfyui"
    echo "  gpu-logs caddy"
}

gpu_links() {
    if [[ -s "$LINKS_FILE" ]]; then
        cat "$LINKS_FILE"
    else
        echo "Ссылки ещё не сформированы."
    fi
}

gpu_test_llm() {
    local model_path="${1:-}"
    local mmproj_path="${2:-}"

    [[ -n "$model_path" ]] || \
        die "Использование: gpu-test-llm /models/test/model.gguf [mmproj.gguf]"

    [[ -f "$model_path" ]] || \
        die "Файл модели не найден: $model_path"

    if [[ ! -S /var/run/gpu-game-supervisor.sock ]]; then
        die "Сначала запусти режим test: gpu-start test"
    fi

    pkill -f "/app/llama-server.*--port 10100" \
        2>/dev/null || true

    local command=(
        /app/llama-server
        --model "$model_path"
        --host 127.0.0.1
        --port 10100
        --ctx-size 16384
        --n-gpu-layers 99
        --flash-attn on
        --parallel 1
        --jinja
    )

    if [[ -n "$mmproj_path" ]]; then
        [[ -f "$mmproj_path" ]] || \
            die "Файл mmproj не найден: $mmproj_path"

        command+=(--mmproj "$mmproj_path")
    fi

    nohup "${command[@]}" \
        > /var/log/gpu-game/test-model.log \
        2>&1 \
        < /dev/null &

    echo "$!" > "$DATA_DIR/test-model.pid"

    log "Тестовая модель запущена на http://127.0.0.1:10100/v1"
    log "Лог: /var/log/gpu-game/test-model.log"
}

show_help() {
    cat <<'EOF'
GPU Game

Модели устанавливаются вручную и не входят в Docker-образ.

Основные команды:

  gpu-start webui [PUBLIC_IP]
      Rocinante + Qwen3-VL + Open WebUI + Caddy

      Требуемые файлы:
        /models/llm/Rocinante-12B-v2i-Q4_K_M.gguf
        /models/vision/Qwen3-VL-8B-Heretic-Stable.Q4_K_M.gguf
        /models/vision/Qwen3-VL-8B-Heretic-Stable.mmproj-bf16.gguf

  gpu-start comfy [PUBLIC_IP]
      ComfyUI + Caddy

      Checkpoint-модели загружаются вручную в:
        /opt/ComfyUI/models/checkpoints

  gpu-start all [PUBLIC_IP]
      Rocinante + Qwen3-VL + Open WebUI + ComfyUI + Caddy

  gpu-start test [PUBLIC_IP]
      Open WebUI + ComfyUI + Caddy без основных LLM

  gpu-stop
      Остановить все сервисы

  gpu-status
      Показать режим, состояние сервисов и видеокарты

  gpu-logs [service]
      Показать список журналов или следить за конкретным журналом

  gpu-links
      Показать HTTPS-ссылки и пароль ComfyUI

  gpu-test-llm MODEL [MMPROJ]
      Запустить тестовую GGUF-модель на порту 10100

Примеры:

  gpu-start comfy

  gpu-start comfy 194.26.196.215

  gpu-start webui

  gpu-start all 194.228.55.129

  gpu-logs comfyui

  gpu-logs caddy

  gpu-test-llm /models/test/model.gguf
EOF
}

COMMAND_NAME="$(basename "$0")"

case "$COMMAND_NAME" in
    gpu-start)
        gpu_start "$@"
        ;;

    gpu-stop)
        gpu_stop
        ;;

    gpu-status)
        gpu_status
        ;;

    gpu-logs)
        gpu_logs "$@"
        ;;

    gpu-links)
        gpu_links
        ;;

    gpu-test-llm)
        gpu_test_llm "$@"
        ;;

    *)
        case "${1:-}" in
            start)
                shift
                gpu_start "$@"
                ;;

            stop)
                gpu_stop
                ;;

            status)
                gpu_status
                ;;

            logs)
                shift
                gpu_logs "$@"
                ;;

            links)
                gpu_links
                ;;

            test-llm)
                shift
                gpu_test_llm "$@"
                ;;

            webui|comfy|all|test)
                gpu_start "$@"
                ;;

            *)
                show_help
                ;;
        esac
        ;;
esac
