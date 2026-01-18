# Dockerfile for vfs_spike
# Build stage
ARG ELIXIR_VERSION=1.18.1
ARG OTP_VERSION=27.2
ARG DEBIAN_VERSION=bookworm-20241202-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# Install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set build ENV
ENV MIX_ENV="prod"

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy config files
COPY mix.exs mix.lock ./
COPY config config

# Install dependencies
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

# Copy application code
COPY lib lib

# Compile and build release
RUN mix compile
RUN mix release

# Runner stage
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR /app

# Create vfs directory
RUN mkdir -p /app/vfs

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/vfs_spike ./

# Set runtime ENV
ENV MIX_ENV="prod"
ENV VFS_SYNC_DIR="/app/vfs"

CMD ["/app/bin/vfs_spike", "start"]
