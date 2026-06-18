FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    bash \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code@2.1.170

RUN pip3 install --break-system-packages \
    flake8 \
    pylint-odoo

WORKDIR /workspace

CMD ["claude"]
