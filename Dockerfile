# ----------------------
# 第一阶段：构建环境
# ----------------------
FROM openresty/openresty:alpine-fat AS builder

ARG MODSEC_VERSION=v3.0.11
ARG MODSEC_NGINX_VERSION=v1.0.4
ARG CRS_VERSION=3.3.4

# 安装编译依赖（新增核心依赖）
RUN apk add --no-cache --virtual .build-deps \
    build-base \
    autoconf \
    automake \
    libtool \
    pcre-dev \
    libxml2-dev \
    yajl-dev \
    lmdb-dev \
    ssdeep-dev \
    git \
    curl \
    linux-headers \
    libmaxminddb-dev \  # 新增地理定位库支持
    libcurl \           # 新增CURL支持
    gcc \
    g++

# 修复关键步骤：编译ModSecurity核心库
RUN git clone --depth 1 --branch ${MODSEC_VERSION} https://github.com/SpiderLabs/ModSecurity && \
    cd ModSecurity && \
    ./build.sh && \
    ./configure \
      --prefix=/usr/local \
      --with-lmdb \
      --with-ssdeep \
      --with-yajl \
      --with-pcre \
      --with-libxml \
      --enable-mlton  \  # 关键修复：启用机器学习解析
      --enable-parser-generation && \
    make -j$(nproc) && \
    make install && \
    # 修复库文件链接
    ln -s /usr/local/modsecurity/lib/libmodsecurity.so.3 /usr/local/lib/

# 修复关键步骤：编译Nginx模块
RUN curl -sL https://github.com/SpiderLabs/ModSecurity-nginx/archive/refs/tags/${MODSEC_NGINX_VERSION}.tar.gz | tar xz && \
    cd /usr/local/openresty/nginx && \
    ./configure \
      --with-compat \
      --add-dynamic-module=../../ModSecurity-nginx-${MODSEC_NGINX_VERSION#v} && \
    make -j$(nproc) modules && \
    # 关键路径修复：确保模块复制到正确位置
    cp objs/ngx_http_modsecurity_module.so modules/ngx_http_modsecurity_module.so

# 下载OWASP规则集（优化配置）
RUN mkdir -p /etc/modsecurity && \
    curl -sL https://github.com/coreruleset/coreruleset/archive/v${CRS_VERSION}.tar.gz | tar xz && \
    mv coreruleset-${CRS_VERSION} /etc/modsecurity/crs && \
    # 清理冗余文件
    find /etc/modsecurity/crs -type f -name "*.example" -delete && \
    # 生成合并配置文件
    echo "Include /etc/modsecurity/modsecurity.conf" > /etc/modsecurity/main.conf && \
    echo "Include /etc/modsecurity/crs/crs-setup.conf" >> /etc/modsecurity/main.conf && \
    echo "Include /etc/modsecurity/crs/rules/*.conf" >> /etc/modsecurity/main.conf

# ----------------------
# 第二阶段：生产镜像
# ----------------------
FROM openresty/openresty:alpine

# 复制编译结果（关键文件修复）
COPY --from=builder \
    /usr/local/openresty/nginx/modules/ngx_http_modsecurity_module.so \
    /usr/local/openresty/nginx/modules/

COPY --from=builder \
    /usr/local/lib/libmodsecurity.so.3 \
    /usr/local/lib/libssdeep.so.2 \
    /usr/local/lib/liblmdb.so.0 \
    /usr/local/lib/libyajl.so.2 \
    /usr/local/lib/

# 复制配置文件
COPY --from=builder /etc/modsecurity /etc/modsecurity

# 安装运行时依赖（新增必要库）
RUN apk add --no-cache \
    libstdc++ \
    lmdb \
    yajl \
    libxml2 \
    pcre \
    ssdeep \
    libcurl \
    libmaxminddb \  # 新增地理定位库
    tini \          # 容器初始化系统
    && ldconfig /usr/local/lib \
    && mkdir -p /var/log/modsecurity \
    && chmod -R 777 /var/log/modsecurity

# 关键配置修复
RUN { \
    echo "load_module modules/ngx_http_modsecurity_module.so;"; \
    echo "env MODSECURITY_RULE_FILE=/etc/modsecurity/main.conf;"; \
    } > /usr/local/openresty/nginx/conf/modsecurity.conf

# 验证模块加载
RUN nginx -t 2>&1 | grep -q "modsecurity module is available"
