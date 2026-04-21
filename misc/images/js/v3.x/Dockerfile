FROM mcr.microsoft.com/playwright:v1.55.0

WORKDIR /app

# Copy package files first for better Docker layer caching
COPY package*.json .aegir.js tsconfig.json ./

# Debug: Check what files were copied
RUN echo "Files in /app:" && ls -la && echo "Package files:" && ls -la package*

# Set environment variables for better npm behavior in Docker
ENV CI=true
# Remove NODE_ENV=production to allow devDependencies installation
ENV NPM_CONFIG_LOGLEVEL=warn
# Increase Node.js memory limit for build processes
ENV NODE_OPTIONS="--max-old-space-size=4096"

# Install dependencies with increased memory and timeout settings
# to handle potential build issues with updated libp2p packages
RUN echo "Node.js version: $(node --version)" && \
    echo "npm version: $(npm --version)" && \
    echo "Starting npm install (removing package-lock.json first)..." && \
    rm -f package-lock.json && \
    npm install --no-audit --no-fund --maxsockets 1 && \
    echo "npm install completed successfully" && \
    echo "Checking what packages are actually installed:" && \
    ls -la node_modules/ | grep -E "(aegir|libp2p|chainsafe)" && \
    echo "Checking if any packages were installed:" && \
    find node_modules/ -maxdepth 1 -type d | wc -l

# Copy source files after dependency installation
COPY src ./src
COPY test ./test

# Build the project with error handling
RUN echo "Checking if aegir is available..." && \
    ls -la node_modules/.bin/aegir && \
    npx aegir --version && \
    npm run build || \
    (echo "Build failed, checking Node.js version and retrying..." && \
     node --version && npm --version && \
     echo "PATH: $PATH" && \
     echo "Checking node_modules/.bin:" && \
     ls -la node_modules/.bin/ | head -10 && \
     npx aegir build --bundle false)

ENTRYPOINT ["npm", "test", "--", "-t", "node", "--", "--exit"]
