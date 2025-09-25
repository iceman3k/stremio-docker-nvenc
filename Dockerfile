# ==============================================================
# 1️⃣  Base image – Ubuntu 22.04 (Jammy) + Manual Node.js 20 install
# ==============================================================
FROM public.ecr.aws/ubuntu/ubuntu:22.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y ca-certificates curl gnupg
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
RUN apt-get install -y nodejs

# Stage to build ffmpeg from source
FROM base AS ffmpeg

# Enable multiverse repository for non-free codecs like fdk-aac
RUN echo "deb http://archive.ubuntu.com/ubuntu/ jammy multiverse" >> /etc/apt/sources.list.d/multiverse.list && \
    echo "deb http://archive.ubuntu.com/ubuntu/ jammy-updates multiverse" >> /etc/apt/sources.list.d/multiverse.list

# We build our own ffmpeg from the jellyfin fork (v7.1.1-7)
ENV BIN="/usr/bin"
RUN BUILD_DEPS=" \
    gnutls-bin \
    libfreetype-dev \
    libgnutls28-dev \
    libmp3lame-dev \
    libass-dev \
    libogg-dev \
    libtheora-dev \
    libvorbis-dev \
    libvpx-dev \
    libwebp-dev \
    libssh2-1-dev \
    libopus-dev \
    librtmp-dev \
    libx264-dev \
    libx265-dev \
    yasm \
    build-essential \
    nasm \
    libdav1d-dev \
    libbluray-dev \
    libdrm-dev \
    libzimg-dev \
    libaom-dev \
    libxvidcore-dev \
    libfdk-aac-dev \
    libva-dev \
    git \
    x264 \
    " && \
    apt-get update && \
    apt-get install -y --no-install-recommends $BUILD_DEPS && \
    DIR=$(mktemp -d) && \
    cd "${DIR}" && \
    git clone --depth 1 --branch v7.1.1-7 https://github.com/jellyfin/jellyfin-ffmpeg.git && \
    cd jellyfin-ffmpeg* && \
    PATH="$BIN:$PATH" && \
    ./configure --bindir="$BIN" --disable-debug \
        --prefix=/usr/lib/jellyfin-ffmpeg --extra-version=Jellyfin --disable-doc --disable-ffplay --disable-shared \
        --disable-libxcb --disable-sdl2 --disable-xlib --enable-lto --enable-gpl --enable-version3 --enable-gmp \
        --enable-gnutls --enable-libdrm --enable-libass --enable-libfreetype --enable-libfribidi --enable-libfontconfig \
        --enable-libbluray --enable-libmp3lame --enable-libopus --enable-libtheora --enable-libvorbis --enable-libdav1d \
        --enable-libwebp --enable-libvpx --enable-libx264 --enable-libx265  --enable-libzimg --enable-small \
        --enable-nonfree --enable-libxvid --enable-libaom --enable-libfdk_aac --enable-vaapi --enable-hwaccel=h264_vaapi \
        --enable-hwaccel=hevc_vaapi --toolchain=hardened && \
    make -j$(nproc) && \
    make install && \
    make distclean && \
    rm -rf "${DIR}"  && \
    apt-get purge -y $BUILD_DEPS && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

#########################################################################

# Builder image for the web UI
FROM base AS builder-web

WORKDIR /srv
RUN apt-get update && apt-get install -y --no-install-recommends git wget dos2unix && rm -rf /var/lib/apt/lists/*

ARG BRANCH=development
RUN REPO="https://github.com/Stremio/stremio-web.git"; if [ "$BRANCH" == "release" ];then git clone "$REPO" --depth 1 --branch $(git ls-remote --tags --refs $REPO | awk \'{print $2}\' | sort -V | tail -n1 | cut -d/ -f3); else git clone --depth 1 --branch "$BRANCH" https://github.com/Stremio/stremio-web.git; fi

WORKDIR /srv/stremio-web

COPY ./load_localStorage.js ./src/load_localStorage.js
RUN sed -i "/entry: {/a \        loader: './src/load_localStorage.js'," webpack.config.js

# Install yarn and build the web project
RUN corepack enable
RUN yarn install --no-audit --no-optional --mutex network --no-progress --ignore-scripts
RUN yarn build

RUN wget $(wget -O- https://raw.githubusercontent.com/Stremio/stremio-shell/master/server-url.txt) && wget -mkEpnp -nH "https://app.strem.io/" "https://app.strem.io/worker.js" "https://app.strem.io/images/stremio.png" "https://app.strem.io/images/empty.png" -P build/shell/ || true
RUN find /srv/stremio-web -type f -not -name "*.png" -exec dos2unix {} +


##########################################################################

# Main image
FROM base AS final

ARG VERSION=main
LABEL org.opencontainers.image.description="Stremio Web Player and Server"
LABEL org.opencontainers.image.licenses=MIT
LABEL version=${VERSION}

WORKDIR /srv/stremio-server
COPY --from=builder-web /srv/stremio-web/build ./build
COPY --from=builder-web /srv/stremio-web/server.js .

RUN adduser --system --no-create-home --group nginx
RUN apt-get update && apt-get install -y --no-install-recommends nginx apache2-utils dos2unix && rm -rf /var/lib/apt/lists/*

COPY ./nginx/ /etc/nginx/
COPY ./stremio-web-service-run.sh .
COPY ./certificate.js .
COPY ./restart_if_idle.sh .
COPY ./ffmpeg-wrapper.sh .
RUN dos2unix ./*.sh

RUN chmod +x ./*.sh

COPY localStorage.json .

# Environment variables
ENV FFMPEG_BIN=/srv/stremio-server/ffmpeg-wrapper.sh
ENV FFPROBE_BIN=
ENV WEBUI_LOCATION=
ENV WEBUI_INTERNAL_PORT=
ENV OPEN=
ENV HLS_DEBUG=
ENV DEBUG=
ENV DEBUG_MIME=
ENV DEBUG_FD=
ENV FFMPEG_DEBUG=
ENV FFSPLIT_DEBUG=
ENV NODE_DEBUG=
ENV NODE_ENV=production
ENV HTTPS_CERT_ENDPOINT=
ENV DISABLE_CACHING=
ENV READABLE_STREAM=
ENV APP_PATH=
ENV NO_CORS=
ENV CASTING_DISABLED=
ENV IPADDRESS=
ENV DOMAIN=
ENV CERT_FILE=
ENV SERVER_URL=
ENV AUTO_SERVER_URL=0
ENV USERNAME=
ENV PASSWORD=

# Copy ffmpeg from the build stage
COPY --from=ffmpeg /usr/bin/ffmpeg /usr/bin/ffprobe /usr/bin/
COPY --from=ffmpeg /usr/lib/jellyfin-ffmpeg /usr/lib/

# Add runtime libraries for ffmpeg
# Note: Some library versions might be specific to Ubuntu 22.04.
RUN RUNTIME_DEPS=" \
    libwebp7 \
    libvorbis0a \
    libx265-199 \
    libx264-163 \
    libass9 \
    libopus0 \
    libgmpxx4ldbl \
    libmp3lame0 \
    libgnutls30 \
    libvpx7 \
    libtheora0 \
    libdrm2 \
    libbluray2 \
    libzimg2 \
    libdav1d5 \
    libaom3 \
    libxvidcore4 \
    libfdk-aac2 \
    libva2 \
    curl \
    procps \
    " && \
    apt-get update && \
    apt-get install -y --no-install-recommends $RUNTIME_DEPS && \
    rm -rf /var/lib/apt/lists/*

# Add architecture-specific libraries (for Intel Quick Sync Video)
RUN if [ "$(uname -m)" = "x86_64" ]; then \
    apt-get update && \
    apt-get install -y --no-install-recommends intel-media-va-driver-non-free mesa-va-drivers && \
    rm -rf /var/lib/apt/lists/*; \
  fi

# Clear cache
RUN rm -rf /tmp/*

VOLUME ["/root/.stremio-server"]

# Expose default ports
EXPOSE 8080

ENTRYPOINT []

CMD ["./stremio-web-service-run.sh"]
