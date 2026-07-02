FROM ghcr.io/ggml-org/llama.cpp:server-cuda

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV UV_UNMANAGED_INSTALL=/usr/local/bin
ENV DATA_DIR=/data/open-webui
ENV ENABLE_OLLAMA_API=false
ENV OPENAI_API_BASE_URL=http://127.0.0.1:10000/v1
ENV OPENAI_API_KEY=gpu-game-local
ENV WEBUI_AUTH=true
ENV UVICORN_WORKERS=1
ENV LD_LIBRARY_PATH=/app

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        wget \
        supervisor \
        python3 \
        python3-venv \
        python3-pip && \
    rm -rf /var/lib/apt/lists/*

RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    uv python install 3.11 && \
    uv venv --python 3.11 /opt/open-webui/venv && \
    uv pip install \
        --python /opt/open-webui/venv/bin/python \
        "open-webui==0.10.2"

RUN mkdir -p \
    /opt/gpu-game \
    /models \
    /data/open-webui \
    /var/log/supervisor

COPY start.sh /opt/gpu-game/start.sh
COPY supervisord.conf /etc/supervisor/conf.d/gpu-game.conf

RUN chmod +x /opt/gpu-game/start.sh

EXPOSE 3000 10000

ENTRYPOINT ["/opt/gpu-game/start.sh"]
