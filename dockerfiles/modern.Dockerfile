# PYTHON 3.12 -> For Odoo v18.0, v19.0 and SaaS versions
FROM python:3.12-slim-bookworm

USER root

# 1. System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    python3-dev \
    libxml2-dev \
    libxslt1-dev \
    libldap2-dev \
    libsasl2-dev \
    libtiff5-dev \
    libjpeg62-turbo-dev \
    libopenjp2-7-dev \
    zlib1g-dev \
    libfreetype6-dev \
    liblcms2-dev \
    libwebp-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libxcb1-dev \
    libpq-dev \
    libcairo2 \
    libcairo2-dev \
    git \
    postgresql-client \
    fontconfig \
    libxrender1 \
    xfonts-75dpi \
    xfonts-base \
    wget \
    && rm -rf /var/lib/apt/lists/*

# 2. Wkhtmltopdf (multi-arch: arm64 + amd64)
ARG TARGETARCH
RUN wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_${TARGETARCH}.deb \
    && apt-get update \
    && apt-get install -y ./wkhtmltox_0.12.6.1-3.bookworm_${TARGETARCH}.deb \
    && rm wkhtmltox_0.12.6.1-3.bookworm_${TARGETARCH}.deb

# 3. Environment setup
RUN useradd -ms /bin/bash odoo
WORKDIR /opt/odoo

# 4. Debugger and version dependencies injection
COPY ./odoo/requirements.txt .
RUN pip install --upgrade pip setuptools wheel --break-system-packages \
    && pip install debugpy --break-system-packages \
    && pip install -r requirements.txt --break-system-packages \
    && pip install pycairo rlPyCairo --break-system-packages

USER odoo
ENV ODOO_RC=/etc/odoo/odoo.conf
