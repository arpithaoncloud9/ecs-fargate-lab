FROM public.ecr.aws/docker/library/node:22-alpine

WORKDIR /app
COPY --chmod=644 package.json server.js ./

ENV NODE_ENV=production PORT=3000
EXPOSE 3000

USER node
CMD ["node", "server.js"]
