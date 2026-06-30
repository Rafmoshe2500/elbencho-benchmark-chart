# ==========================================
# Stage 1: Build elbencho from source
# ==========================================
FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies required for compilation
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    libaio-dev \
    libboost-filesystem-dev \
    libboost-program-options-dev \
    libboost-thread-dev \
    libcurl4-openssl-dev \
    libnuma-dev \
    libssl-dev \
    uuid-dev \
    zlib1g-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Clone the elbencho repository at the specified version
WORKDIR /src
ARG ELBENCHO_VERSION=3.1-5
RUN git clone --depth 1 --branch v${ELBENCHO_VERSION} https://github.com/breuner/elbencho.git .

# Build elbencho
# NCURSES_SUPPORT=OFF is used because interactive dashboard features are not required in containers.
RUN mkdir build && cd build && \
    cmake -DNCURSES_SUPPORT=OFF .. && \
    make -j$(nproc)

# ==========================================
# Stage 2: Create the minimal runtime image
# ==========================================
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime shared libraries required by the compiled binary
RUN apt-get update && apt-get install -y --no-install-recommends \
    libaio1 \
    libboost-filesystem1.74.0 \
    libboost-program-options1.74.0 \
    libboost-thread1.74.0 \
    libcurl4 \
    libnuma1 \
    libssl3 \
    uuid-runtime \
    zlib1g \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the compiled binary from the builder stage
COPY --from=builder /src/build/elbencho /usr/local/bin/elbencho

# Set entrypoint to elbencho
ENTRYPOINT ["/usr/local/bin/elbencho"]
CMD ["--help"]
