FROM node:20 AS base

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NODE_ENV=production \
    YTDLP_PATH=/usr/local/bin/yt-dlp \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    DOWNLOAD_PATH=/tmp/downloads \
    PORT=3000

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip ffmpeg curl wget ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Verify ffmpeg is at known path
RUN which ffmpeg && ffmpeg -version 2>&1 | head -1

# Install yt-dlp as binary (not pip) — more reliable, always latest
RUN wget -q "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" \
    -O /usr/local/bin/yt-dlp && chmod a+rx /usr/local/bin/yt-dlp \
    && yt-dlp --version

# Bake yt-dlp config: Node.js runtime + sensible defaults
RUN mkdir -p /root/.config/yt-dlp && cat > /root/.config/yt-dlp/config << 'YTCONF'
--js-runtimes nodejs
--retries 5
--fragment-retries 5
--socket-timeout 60
--no-cache-dir
--no-part
--newline
YTCONF

# Create writable download dir
RUN mkdir -p /tmp/downloads && chmod 777 /tmp/downloads

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY src/ ./src/
COPY cookies/ ./cookies/
RUN mkdir -p logs

EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1
CMD ["node", "src/server.js"]

FROM base AS worker
CMD ["node", "src/workers/download.worker.js"]
