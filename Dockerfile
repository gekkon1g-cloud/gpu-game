FROM ghcr.io/ggml-org/llama.cpp:server-cuda13 AS llama

FROM ghcr.io/open-webui/open-webui:main

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        curl \
        wget \
        ca-certificates \
        bash && \
    rm -rf /var/lib/apt/lists/*

COPY --from=llama /app /opt/llama

RUN mkdir -p \
    /opt/gpu-game \
    /models \
    /app/backend/data \
    /var/log/supervisor

COPY start.sh /opt/gpu-game/start.sh
COPY supervisord.conf /etc/supervisor/conf.d/gpu-game.conf

RUN chmod +x /opt/gpu-game/start.sh

ENV DATA_DIR=/app/backend/data
ENV ENABLE_OLLAMA_API=false
ENV OPENAI_API_BASE_URL=http://127.0.0.1:10000/v1
ENV OPENAI_API_KEY=gpu-game-local
ENV WEBUI_AUTH=true
ENV UVICORN_WORKERS=1
ENV LD_LIBRARY_PATH=/opt/llama

EXPOSE 3000 10000

ENTRYPOINT ["/opt/gpu-game/start.sh"]   
