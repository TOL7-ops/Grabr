FROM node:20 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production \
    YTDLP_PATH=/usr/local/bin/yt-dlp \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    DOWNLOAD_PATH=/tmp/downloads \
    PORT=3000

# System deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip ffmpeg curl wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Verify ffmpeg
RUN which ffmpeg && ffmpeg -version 2>&1 | head -1

# Install yt-dlp as binary (not pip) — always latest, more reliable
RUN wget -q "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" \
    -O /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp \
    && yt-dlp --version

# Tell yt-dlp where Node.js binary is for JS runtime
# The flag is "--js-runtimes node" (NOT "nodejs")
# Full path ensures it's found even if PATH differs
RUN mkdir -p /root/.config/yt-dlp && \
    NODE_BIN=$(which node) && \
    echo "--js-runtimes node:${NODE_BIN}" > /root/.config/yt-dlp/config && \
    echo "--retries 5"                   >> /root/.config/yt-dlp/config && \
    echo "--socket-timeout 60"           >> /root/.config/yt-dlp/config && \
    echo "--no-cache-dir"                >> /root/.config/yt-dlp/config && \
    cat /root/.config/yt-dlp/config

# Verify yt-dlp can find node runtime
RUN yt-dlp --version && echo "yt-dlp config OK"

# Create writable download dir
RUN mkdir -p /tmp/downloads && chmod 777 /tmp/downloads

WORKDIR /app

COPY package*.json ./
RUN npm ci --only=production

COPY src/ ./src/

# CRITICAL: copy cookies so YouTube bot check passes
COPY cookies/ ./cookies/

RUN mkdir -p logs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]

FROM base AS worker
CMD ["node", "src/workers/download.worker.js"]
