# ----------------------
# 第一阶段：构建环境
# ----------------------
FROM debian:bookworm-slim AS builder

ARG MODSEC3_VERSION=3.0.11
ARG CRS_VERSION=3.3.4
ARG LMDB_VERSION=0.9.31
ARG LUA_VERSION=5.1

# 安装构建依赖
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential \
    automake \
    cmake \
    libtool \
    git \
    curl \
    libcurl4-gnutls-dev \
    libfuzzy-dev \
    liblua${LUA_VERSION}-dev \
    libpcre3-dev \
    libpcre2-dev \
    libxml2-dev \
    libmaxminddb-dev \
    libyajl-dev \
    zlib1g-dev \
    pkg-config \
    ruby

# 构建LMDB
WORKDIR /sources
RUN git clone --branch LMDB_${LMDB_VERSION} --depth 1 https://github.com/LMDB/lmdb && \
    make -C lmdb/libraries/liblmdb install && \
    strip /usr/local/lib/liblmdb.so*

# 构建ModSecurity
RUN git clone --depth 1 --branch v${MODSEC3_VERSION} https://github.com/owasp-modsecurity/ModSecurity && \
    cd ModSecurity && \
    ./build.sh && \
    ./configure \
      --with-yajl \
      --with-ssdeep \
      --with-pcre2 \
      --with-maxmind \
      --enable-shared \
      --enable-static && \
    make -j$(nproc) install && \
    ldconfig

# ----------------------
# 第二阶段：运行时环境
# ----------------------
FROM openresty/openresty:bullseye

ARG MODSEC3_VERSION
ARG LUA_VERSION
ARG CRS_VERSION

# 复制构建产物
COPY --from=builder /usr/local/lib/liblmdb.so* /usr/local/lib/
COPY --from=builder /usr/local/modsecurity/ /usr/local/modsecurity/

# 安装运行时依赖
RUN apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    libcurl4-gnutls-dev \
    libfuzzy2 \
    liblua${LUA_VERSION} \
    libxml2 \
    libyajl2 \
    libmaxminddb-dev \
    ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# 配置动态库路径
ENV LD_LIBRARY_PATH /usr/local/lib:/usr/local/modsecurity/lib:$LD_LIBRARY_PATH

# 创建必要目录
RUN mkdir -p \
    /var/log/modsecurity \
    /etc/modsecurity.d \
    /opt/owasp-crs \
    /tmp/modsecurity/{data,upload,tmp}

# 复制CRS规则集
COPY --from=owasp/modsecurity-crs:${CRS_VERSION} /opt/owasp-crs /opt/owasp-crs

# 配置文件和模板
COPY config/modsecurity.conf /etc/modsecurity.d/
COPY config/crs-setup.conf /opt/owasp-crs/
COPY nginx.conf /usr/local/openresty/nginx/conf/

# 符号链接处理
RUN ln -s /usr/local/modsecurity/lib/libmodsecurity.so.${MODSEC3_VERSION} \
    /usr/local/modsecurity/lib/libmodsecurity.so && \
    ldconfig

# 安全加固
RUN chown -R nobody:nogroup \
    /var/log/modsecurity \
    /tmp/modsecurity && \
    find /tmp/modsecurity -type d -exec chmod 1777 {} \;

# 健康检查
HEALTHCHECK --interval=30s --timeout=10s \
    CMD curl -f http://localhost:8080/health || exit 1

EXPOSE 8080 8443

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
