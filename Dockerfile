FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY server.js db.js queue.js ./
COPY routes ./routes
COPY mgmt_flow_dashboard.html ./

EXPOSE 3000

CMD ["npm", "start"]
