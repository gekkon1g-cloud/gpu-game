FROM ghcr.io/open-webui/open-webui:main AS openwebui

FROM ghcr.io/ggml-org/llama.cpp:server-cuda13

USER root

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

COPY --from=openwebui /app /app

RUN mkdir -p \
    /opt/gpu-game \
    /models \
    /data/open-webui \
    /var/log/supervisor

COPY start.sh /opt/gpu-game/start.sh
COPY supervisord.conf /etc/supervisor/conf.d/gpu-game.conf

RUN chmod +x /opt/gpu-game/start.sh

ENV DATA_DIR=/data/open-webui
ENV ENABLE_OLLAMA_API=false
ENV OPENAI_API_BASE_URL=http://127.0.0.1:10000/v1
ENV OPENAI_API_KEY=gpu-game-local
ENV WEBUI_AUTH=true
ENV UVICORN_WORKERS=1

EXPOSE 3000 10000

ENTRYPOINT ["/opt/gpu-game/start.sh"]
