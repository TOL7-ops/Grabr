FROM node:20-slim AS base

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    ffmpeg \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install yt-dlp via pip
RUN pip3 install --no-cache-dir --break-system-packages yt-dlp

# Verify yt-dlp is available
RUN yt-dlp --version

WORKDIR /app

# Install Node dependencies
COPY package*.json ./
RUN npm ci --only=production

# Copy source
COPY src/ ./src/

# Create downloads dir
RUN mkdir -p downloads logs

# Non-root user for security
RUN useradd -r -u 1001 -g root appuser \
    && chown -R appuser:root /app
USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

CMD ["node", "src/server.js"]

# ── Worker stage ──────────────────────────────────────────────────────────────
FROM base AS worker
CMD ["node", "src/workers/download.worker.js"]