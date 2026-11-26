# install node and browsers
FROM mcr.microsoft.com/playwright:v1.55.0

WORKDIR /app

COPY package*.json .aegir.js tsconfig.json ./
COPY src ./src
COPY test ./test

# disable colored output and CLI animation from test runners
ENV CI=true

# install inside the container so any native deps will have the docker arch
RUN npm ci
RUN npm run build

# Node.js can munge SDP, so the default WebRTC Direct dialer uses v1
ENV EXPECT_WEBRTC_DIRECT_VERSION=1

ENTRYPOINT ["npm", "test", "--", "-t", "node", "--", "--exit"]
