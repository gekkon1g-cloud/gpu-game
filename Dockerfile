FROM ghcr.io/ggml-org/llama.cpp:server-cuda

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV UV_UNMANAGED_INSTALL=/usr/local/bin

# Open WebUI
ENV DATA_DIR=/data/open-webui
ENV ENABLE_OLLAMA_API=false
ENV WEBUI_AUTH=true
ENV WORKERS=1

# llama.cpp
ENV LD_LIBRARY_PATH=/app

# Версии, которые уже были проверены в проекте
ARG OPEN_WEBUI_VERSION=0.10.2
ARG COMFYUI_VERSION=v0.27.0
ARG CLOUDFLARED_VERSION=2026.7.1

# Системные зависимости
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        wget \
        git \
        jq \
        openssl \
        procps \
        iproute2 \
        netcat-openbsd \
        supervisor \
        gettext-base \
        python3 \
        python3-venv \
        python3-pip \
        xz-utils \
        tar \
        unzip \
        gnupg \
        debian-keyring \
        debian-archive-keyring \
        apt-transport-https && \
    rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------------------
# uv и отдельные Python-окружения
# -------------------------------------------------------------------

RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Open WebUI — отдельный Python 3.11
RUN uv python install 3.11 && \
    uv venv --python 3.11 /opt/open-webui/venv && \
    uv pip install \
        --python /opt/open-webui/venv/bin/python \
        "open-webui==${OPEN_WEBUI_VERSION}"

# ComfyUI — отдельный Python 3.12
RUN uv python install 3.12 && \
    git clone \
        --branch "${COMFYUI_VERSION}" \
        --depth 1 \
        https://github.com/Comfy-Org/ComfyUI.git \
        /opt/ComfyUI && \
    uv venv --python 3.12 /opt/ComfyUI/venv

# PyTorch, torchvision и torchaudio из одного CUDA-репозитория.
# Это исключает конфликт CUDA-версий между torch и torchaudio.
RUN uv pip install \
        --python /opt/ComfyUI/venv/bin/python \
        torch \
        torchvision \
        torchaudio \
        --index-url https://download.pytorch.org/whl/cu130 && \
    uv pip install \
        --python /opt/ComfyUI/venv/bin/python \
        -r /opt/ComfyUI/requirements.txt

# -------------------------------------------------------------------
# Caddy
# -------------------------------------------------------------------

RUN curl -1sLf \
        'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        -o /usr/share/keyrings/caddy-stable-archive-keyring.asc && \
    curl -1sLf \
        'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        -o /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends caddy && \
    rm -rf /var/lib/apt/lists/*

# -------------------------------------------------------------------
# Cloudflare Quick Tunnel — резервный вариант доступа
# -------------------------------------------------------------------

RUN wget -O /usr/local/bin/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64" && \
    chmod +x /usr/local/bin/cloudflared

# -------------------------------------------------------------------
# Каталоги проекта и моделей
# -------------------------------------------------------------------

RUN mkdir -p \
        /opt/gpu-game \
        /models/llm \
        /models/vision \
        /models/test \
        /models/downloads \
        /data/open-webui \
        /data/gpu-game \
        /data/caddy \
        /config/caddy \
        /var/log/gpu-game \
        /var/log/supervisor \
        /opt/ComfyUI/models/checkpoints \
        /opt/ComfyUI/models/vae \
        /opt/ComfyUI/models/loras \
        /opt/ComfyUI/models/controlnet \
        /opt/ComfyUI/models/clip_vision \
        /opt/ComfyUI/models/ipadapter

# Файлы управления будут добавлены следующими шагами
COPY start.sh /opt/gpu-game/start.sh
COPY supervisord.conf /etc/supervisor/conf.d/gpu-game.conf
COPY Caddyfile.template /opt/gpu-game/Caddyfile.template

RUN chmod +x /opt/gpu-game/start.sh && \
    touch /opt/gpu-game/.webui_secret_key && \
    chmod 600 /opt/gpu-game/.webui_secret_key

# Порты внутри контейнера.
# Наружу фактически планируем использовать 80/443 через Caddy.
EXPOSE 80 443 3000 8188 10000 10001 10100

WORKDIR /opt/gpu-game

ENTRYPOINT ["/opt/gpu-game/start.sh"]
