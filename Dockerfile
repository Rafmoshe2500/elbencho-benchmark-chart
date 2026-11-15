# elbencho image built from the official STATIC release binary.
#
# Why not the official breuner/elbencho image: it is Ubuntu 24.04/26.04 based and uses the system libaio
# 0.3.113, which implements io_getevents() with the io_pgetevents syscall. The default seccomp profile of
# CRI-O (OpenShift "RuntimeDefault") denies io_pgetevents with EPERM, so every run with --iodepth > 1 fails:
#   ERROR: Getting async IO events (io_getevents) failed ... SysErr: Operation not permitted
# The static binary carries its own libaio, which uses the io_getevents syscall that the profile allows.
#
# Build and push:
#   docker build -t <your-repo>/elbencho:3.3-3 .
#   docker push <your-repo>/elbencho:3.3-3
# Other version / ARM:  --build-arg ELBENCHO_VERSION=3.3-3 --build-arg ELBENCHO_ARCH=aarch64
FROM ubuntu:22.04

ARG ELBENCHO_VERSION=3.3-3
ARG ELBENCHO_ARCH=x86_64

# CA certificates for S3 over https. bash and coreutils (used by the Helm chart and benchmarks/) are in the base.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ADD https://github.com/breuner/elbencho/releases/download/v${ELBENCHO_VERSION}/elbencho-static-${ELBENCHO_ARCH}.tar.gz /tmp/elbencho.tar.gz

# Extract, and fail the build if the binary does not run
RUN tar -xzf /tmp/elbencho.tar.gz -C /usr/local/bin elbencho \
    && chmod 755 /usr/local/bin/elbencho \
    && rm /tmp/elbencho.tar.gz \
    && /usr/local/bin/elbencho --version

ENTRYPOINT ["/usr/local/bin/elbencho"]
CMD ["--help"]
