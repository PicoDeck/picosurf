FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production PORT=8080
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY tsconfig.json ./
COPY src ./src
USER node
EXPOSE 8080
CMD ["npx", "tsx", "src/serve.ts"]
