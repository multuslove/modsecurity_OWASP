# ----------------------
# 第一阶段：精准构建环境
# ----------------------
FROM openresty/openresty:alpine-fat AS builder

# 使用官方推荐版本组合（已验证兼容性）
ARG MODSEC_VERSION=v3.0.11
ARG MODSEC_NGINX_VERSION=v1.0.4
ARG CRS_VERSION=3.3.4

# 精准安装编译依赖（Alpine特有包名）
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
    libmaxminddb-dev \
    geoip-dev

# —— 关键步骤1：编译ModSecurity3 ——
RUN git clone --depth 1 --branch ${MODSEC_VERSION} https://github.com/SpiderLabs/ModSecurity && \
    cd ModSecurity && \
    # Alpine系统必须的构建调整
    sed -i 's/--enable-shared/--enable-static --disable-shared/g' build.sh && \
    ./build.sh && \
    ./configure \
      --prefix=/usr/local \
      --with-lmdb \
      --with-ssdeep \
      --with-yajl \
      --with-pcre \
      --with-libxml \
      --enable-static \
      --disable-shared && \
    make -j$(nproc) && \
    make install

# —— 关键步骤2：编译Nginx模块 ——
RUN curl -sSL https://github.com/SpiderLabs/ModSecurity-nginx/archive/refs/tags/${MODSEC_NGINX_VERSION}.tar.gz | \
    tar -xz && \
    cd /usr/local/openresty/nginx && \
    # 精准匹配OpenResty的configure参数
    ./configure \
      --with-compat \
      --with-cc-opt='-DNGX_HTTP_MODSECURITY -I/usr/local/include/ModSecurity' \
      --add-dynamic-module=../../ModSecurity-nginx-${MODSEC_NGINX_VERSION#v} && \
    make -j$(nproc) modules && \
    # 强制验证模块存在
    test -f objs/ngx_http_modsecurity_module.so && \
    cp objs/ngx_http_modsecurity_module.so modules/

# —— 关键步骤3：准备规则集 ——
RUN mkdir -p /etc/modsecurity && \
    curl -sSL https://github.com/coreruleset/coreruleset/archive/v${CRS_VERSION}.tar.gz | tar -xz && \
    mv coreruleset-${CRS_VERSION} /etc/modsecurity/crs && \
    # 生成合并配置
    printf "# Auto-generated config\nInclude /etc/modsecurity/crs/crs-setup.conf\nInclude /etc/modsecurity/crs/rules/*.conf" \
    > /etc/modsecurity/main.conf

# ----------------------
# 第二阶段：精简直销镜像
# ----------------------
FROM openresty/openresty:alpine

# 精准复制产物（Alpine路径严格校验）
COPY --from=builder \
    /usr/local/openresty/nginx/modules/ngx_http_modsecurity_module.so \
    /usr/local/openresty/nginx/modules/

COPY --from=builder \
    /usr/local/lib/libmodsecurity.a \
    /usr/local/lib/libssdeep.* \
    /usr/local/lib/liblmdb.* \
    /usr/local/lib/libyajl.* \
    /usr/local/lib/

# 复制配置文件
COPY --from=builder /etc/modsecurity /etc/modsecurity

# Alpine运行时依赖（最小化安装）
RUN apk add --no-cache \
    libstdc++ \
    lmdb \
    yajl \
    libxml2 \
    pcre \
    ssdeep \
    libmaxminddb \
    && ln -s /usr/lib/libssdeep.so.2 /usr/lib/libssdeep.so \
    && ln -s /usr/lib/liblmdb.so.0 /usr/lib/liblmdb.so \
    && ln -s /usr/lib/libyajl.so.2 /usr/lib/libyajl.so \
    && ldconfig /usr/lib

# 强制模块加载验证
RUN echo "load_module modules/ngx_http_modsecurity_module.so;" \
    > /usr/local/openresty/nginx/conf/modsecurity.load && \
    nginx -t 2>&1 | grep -q "modsecurity module is available"

# 安全增强配置
RUN mkdir -p /var/log/modsecurity && \
    chown -R nobody:nogroup /var/log/modsecurity && \
    sed -i \
      -e 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' \
      -e 's#SecAuditLog /var/log/modsec_audit.log#SecAuditLog /var/log/modsecurity/audit.log#' \
      /etc/modsecurity/modsecurity.conf
