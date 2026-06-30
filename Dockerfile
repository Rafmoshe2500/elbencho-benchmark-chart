# ==========================================
# Stage 1: Download the official static binary
# ==========================================
FROM alpine:3.19 AS downloader

RUN apk add --no-cache curl tar

ARG ELBENCHO_VERSION=3.1-5

# Download and extract the official pre-compiled static executable
RUN curl -L -o elbencho.tar.gz https://github.com/breuner/elbencho/releases/download/v${ELBENCHO_VERSION}/elbencho-static-x86_64.tar.gz \
    && tar -xzf elbencho.tar.gz \
    && chmod +x elbencho

# ==========================================
# Stage 2: Create the minimal final image
# ==========================================
FROM ubuntu:22.04

# Install basic runtime packages (no boost/libaio needed for static binary)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the static binary from the downloader stage
COPY --from=downloader /elbencho /usr/local/bin/elbencho

# Set entrypoint to elbencho
ENTRYPOINT ["/usr/local/bin/elbencho"]
CMD ["--help"]
