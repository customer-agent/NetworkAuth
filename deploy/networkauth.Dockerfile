# NetworkAuth is a Go binary with the Vue frontend embedded into it.
# Keep the frontend and backend builds in one image so the deployed artefact
# always contains matching API routes and static assets.
FROM node:22-bookworm AS frontend

WORKDIR /src/frontend
ARG NPM_REGISTRY=https://registry.npmmirror.com
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    no_proxy=${NO_PROXY} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}
RUN corepack enable \
    && corepack prepare pnpm@10.15.0 --activate \
    && npm config set registry "$NPM_REGISTRY"
COPY frontend/package.json frontend/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile
COPY frontend/ ./
RUN pnpm run build

FROM golang:1.25-bookworm AS backend

WORKDIR /src
ARG GOPROXY=https://goproxy.cn,direct
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV GOPROXY=${GOPROXY} \
    http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    no_proxy=${NO_PROXY} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY}
RUN apt-get update \
    && apt-get install --no-install-recommends --yes git python3 \
    && rm -rf /var/lib/apt/lists/*
COPY go.mod go.sum ./
RUN go mod download
COPY . .
COPY --from=frontend /src/frontend/dist ./frontend/dist
RUN CGO_ENABLED=0 go test ./tests \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/networkauth ./main.go

FROM debian:bookworm-slim

ARG BUILD_VERSION=source
LABEL org.opencontainers.image.title="NetworkAuth" \
      org.opencontainers.image.description="NetworkAuth web and API service" \
      org.opencontainers.image.version="${BUILD_VERSION}"

RUN apt-get update \
    && apt-get install --no-install-recommends --yes ca-certificates curl tzdata \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --create-home --home-dir /home/networkauth networkauth

WORKDIR /app
COPY --from=backend /out/networkauth /usr/local/bin/networkauth
COPY --from=backend /src/data /usr/local/share/networkauth-data
RUN mkdir -p /app/config /app/data /app/logs \
    && chown -R networkauth:networkauth /app

USER networkauth
EXPOSE 8080
ENV TZ=Asia/Shanghai
ENTRYPOINT ["/usr/local/bin/networkauth"]
CMD ["--config", "/app/config/config.json", "server", "--host", "0.0.0.0", "--port", "8080"]
