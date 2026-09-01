FROM debian:trixie
RUN apt-get update && apt-get install -y --no-install-recommends \
        iverilog python3 git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
