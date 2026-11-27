FROM node:22-alpine

RUN apk add --no-cache ffmpeg

WORKDIR /app

# Copy package files and install production dependencies
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Copy application source
COPY src ./src

# Create default directories
RUN mkdir -p /storage /app/data

ENV NODE_ENV=production
ENV PORT=3000
ENV WEB_PORT=4000
ENV STORAGE_DIR=/storage
ENV DATA_DIR=/app/data

EXPOSE 3000 4000

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "const http = require('http'); const req = http.get({ host: '127.0.0.1', port: process.env.PORT || 3000, path: '/api/health', timeout: 4000 }, (res) => process.exit(res.statusCode === 200 ? 0 : 1)); req.on('error', () => process.exit(1));"

CMD ["node", "src/server.js"]
