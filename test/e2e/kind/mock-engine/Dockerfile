# Fake sglang and vllm binaries for the kind cache e2e.
# The chart's command stays the real one: python3 cache_manager.py -- <engine> serve ...
# cache_manager.py execs the engine name from PATH, which is this image.
FROM python:3.12-slim

COPY engine.py /usr/local/bin/mock-engine.py
RUN printf '%s\n' \
      '#!/bin/sh' \
      'exec python3 /usr/local/bin/mock-engine.py "$@"' \
      > /usr/local/bin/sglang \
    && cp /usr/local/bin/sglang /usr/local/bin/vllm \
    && chmod 0755 /usr/local/bin/sglang /usr/local/bin/vllm
