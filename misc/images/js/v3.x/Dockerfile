FROM mcr.microsoft.com/playwright:v1.55.0

WORKDIR /app

COPY package*.json .aegir.js tsconfig.json ./
COPY src ./src
COPY test ./test

ENV CI=true

RUN npm ci
RUN npm run build

ENTRYPOINT ["npm", "test", "--", "-t", "node", "--", "--exit"]
