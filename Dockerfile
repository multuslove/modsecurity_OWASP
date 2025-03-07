# ----------------------
# 第一阶段：构建环境
# ----------------------
FROM openresty/openresty:alpine-fat AS builder

ARG MODSEC_VERSION
ARG MODSEC_NGINX_VERSION
ARG CRS_VERSION

# 安装编译依赖
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
    curl

# 编译 ModSecurity 核心库
RUN git clone --depth 1 --branch ${MODSEC_VERSION} https://github.com/SpiderLabs/ModSecurity && \
    cd ModSecurity && \
    ./build.sh && \
    ./configure \
      --prefix=/usr/local \
      --with-lmdb \
      --with-ssdeep \
      --with-yajl \
      --with-pcre \
      --with-libxml && \
    make -j$(nproc) && \
    make install

# 编译 Nginx 模块
RUN curl -sL https://github.com/SpiderLabs/ModSecurity-nginx/archive/${MODSEC_NGINX_VERSION}.tar.gz | tar xz && \
    cd /usr/local/openresty/nginx && \
    ./configure --with-compat --add-dynamic-module=../../ModSecurity-nginx-${MODSEC_NGINX_VERSION#v} && \
    make modules && \
    cp objs/ngx_http_modsecurity_module.so modules/

# 下载 OWASP 规则集
RUN curl -sL https://github.com/coreruleset/coreruleset/archive/v${CRS_VERSION}.tar.gz | tar xz && \
    mv coreruleset-${CRS_VERSION} /etc/modsecurity/crs && \
    rm -rf /etc/modsecurity/crs/.git* && \
    echo "Include /etc/modsecurity/crs/crs-setup.conf" >> /etc/modsecurity/modsecurity.conf && \
    echo "Include /etc/modsecurity/crs/rules/*.conf" >> /etc/modsecurity/modsecurity.conf

# ----------------------
# 第二阶段：生产镜像
# ----------------------
FROM openresty/openresty:alpine

# 复制编译结果
COPY --from=builder /usr/local/openresty/nginx/modules/ngx_http_modsecurity_module.so /usr/local/openresty/nginx/modules/
COPY --from=builder /usr/local/lib/libmodsecurity.so.3 /usr/local/lib/
COPY --from=builder /etc/modsecurity /etc/modsecurity

# 安装运行时依赖
RUN apk add --no-cache \
    libstdc++ \
    lmdb \
    yajl \
    libxml2 \
    pcre \
    ssdeep && \
    ldconfig /usr/local/lib && \
    # 创建审计日志目录
    mkdir -p /var/log/modsecurity && \
    # 修改配置文件
    sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' /etc/modsecurity/modsecurity.conf && \
    sed -i 's#SecAuditLog /var/log/modsec_audit.log#SecAuditLog "|/usr/bin/tee -a /var/log/modsec_audit.log"#' /etc/modsecurity/modsecurity.conf

# 验证模块加载
RUN echo "load_module modules/ngx_http_modsecurity_module.so;" > /usr/local/openresty/nginx/conf
