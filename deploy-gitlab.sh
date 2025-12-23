#!/bin/bash
# deploy-gitlab.sh - 一键部署 GitLab with auto-generated strong passwords

set -e

# 安装 acme.sh（支持 100+ DNS 提供商，包括阿里云）
# curl https://get.acme.sh | sh

GITLAB_DIR="$HOME/gitlab"
DOMAIN="gitlab.waytronic.tech"
SECRETS_FILE="$GITLAB_DIR/secrets.env"

log() {
    echo -e "\033[1;32m[$(date +'%Y-%m-%d %H:%M:%S')] $*\033[0m"
}

error() {
    echo -e "\033[1;31m[ERROR] $*\033[0m" >&2
    exit 1
}

# 检查依赖
command -v openssl >/dev/null || error "需要 openssl，请先安装"
command -v docker compose >/dev/null || error "需要 docker compose，请先安装"

# 创建目录
mkdir -p "$GITLAB_DIR"/{nginx/ssl,postgres/data,redis/data,minio/data,gitlab/{config,logs,data},runner/config,backups}

# === 密码管理 ===
if [ -f "$SECRETS_FILE" ]; then
    log "检测到已存在 secrets.env，加载现有密码..."
    source "$SECRETS_FILE"
else
    log "生成强密码..."
    DB_PASSWORD=$(openssl rand -base64 32 | tr -d '\n' | cut -c1-32)
    MINIO_PASSWORD=$(openssl rand -base64 32 | tr -d '\n' | cut -c1-32)
    SMTP_PASSWORD=$(openssl rand -base64 24 | tr -d '\n' | cut -c1-24)

    # 保存到 secrets.env
    cat > "$SECRETS_FILE" <<EOF
# GitLab 部署密钥（自动生成）
DB_PASSWORD='$DB_PASSWORD'
MINIO_PASSWORD='$MINIO_PASSWORD'
SMTP_PASSWORD='$SMTP_PASSWORD'
EOF
    chmod 600 "$SECRETS_FILE"
    log "✅ 密码已保存到 $SECRETS_FILE（权限 600）"
fi

# 转义特殊字符用于 YAML（主要是单引号）
escape_yaml() {
    local str="$1"
    # 在 YAML 单引号字符串中，只需处理连续两个单引号（但我们的密码不含 '）
    # 所以直接原样输出即可。若未来含 '，可改用双引号 + 转义
    echo "$str"
}

DB_PASS_YAML=$(escape_yaml "$DB_PASSWORD")
MINIO_PASS_YAML=$(escape_yaml "$MINIO_PASSWORD")
SMTP_PASS_YAML=$(escape_yaml "$SMTP_PASSWORD")

# === 生成 docker-compose.yml ===
cat > "$GITLAB_DIR/docker-compose.yml" <<EOF
version: '3.8'

services:
  postgresql:
    image: postgres:15
    restart: always
    environment:
      POSTGRES_USER: gitlab
      POSTGRES_PASSWORD: '$DB_PASS_YAML'
      POSTGRES_DB: gitlabhq_production
    volumes:
      - ./postgres/data:/var/lib/postgresql/data
    networks:
      - gitlab-net

  redis:
    image: redis:7-alpine
    restart: always
    command: ["--appendonly", "yes"]
    volumes:
      - ./redis/data:/data
    networks:
      - gitlab-net

  minio:
    image: minio/minio:latest
    restart: always
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: '$MINIO_PASS_YAML'
    volumes:
      - ./minio/data:/data
    ports:
      - "127.0.0.1:9000:9000"
      - "127.0.0.1:9001:9001"
    networks:
      - gitlab-net

  postfix:
    image: catatnight/postfix:latest
    restart: always
    environment:
      maildomain: waytronic.tech
      smtp_user: noreply:$SMTP_PASS_YAML
    ports:
      - "127.0.0.1:2525:25"
    networks:
      - gitlab-net

  gitlab:
    image: gitlab/gitlab-ce:latest
    restart: always
    hostname: $DOMAIN
    depends_on:
      - postgresql
      - redis
      - minio
      - postfix
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://$DOMAIN'
        registry_external_url 'https://registry.$DOMAIN/'

        nginx['enable'] = false
        postgresql['enable'] = false
        redis['enable'] = false

        gitlab_rails['db_host'] = 'postgresql'
        gitlab_rails['db_port'] = 5432
        gitlab_rails['db_username'] = 'gitlab'
        gitlab_rails['db_password'] = '$DB_PASS_YAML'
        gitlab_rails['db_database'] = 'gitlabhq_production'
        gitlab_rails['redis_host'] = 'redis'
        gitlab_rails['redis_port'] = 6379

        gitlab_rails['smtp_enable'] = true
        gitlab_rails['smtp_address'] = 'postfix'
        gitlab_rails['smtp_port'] = 25
        gitlab_rails['smtp_domain'] = 'waytronic.tech'
        gitlab_rails['smtp_authentication'] = false
        gitlab_rails['smtp_tls'] = false
        gitlab_rails['gitlab_email_from'] = 'gitlab@$DOMAIN'

        gitlab_pages['enable'] = true
        pages_external_url 'http://pages.$DOMAIN/'
        gitlab_pages['inplace_chroot'] = true

        gitlab_rails['packages_enabled'] = true
        gitlab_rails['container_registry_enabled'] = true
        gitlab_rails['ci_enabled'] = true

        gitlab_rails['max_request_size_bytes'] = 1073741824

        gitlab_rails['object_store']['enabled'] = true
        gitlab_rails['object_store']['proxy_download'] = true
        #'provider' => 'AWS', ← 表示使用 S3 协议（不是必须连 AWS）
        #'region' => 'us-east-1',            # ← 随便填一个合法 region（MinIO 不关心）
        # 真正配置到aws,其host和endpoint是指向aws云的。
        gitlab_rails['object_store']['connection'] = {
          'provider' => 'AWS',
          'region' => 'us-east-1',
          'aws_access_key_id' => 'minioadmin',
          'aws_secret_access_key' => '$MINIO_PASS_YAML',
          'host' => 'minio:9000',
          'endpoint' => 'http://minio:9000',
          'path_style' => true
        }

        gitlab_rails['artifacts_object_store_enabled'] = true
        gitlab_rails['uploads_object_store_enabled'] = true
        gitlab_rails['lfs_object_store_enabled'] = true
        gitlab_rails['packages_object_store_enabled'] = true
        gitlab_rails['dependency_proxy_object_store_enabled'] = true
        gitlab_rails['terraform_state_object_store_enabled'] = true
        gitlab_rails['ci_secure_files_object_store_enabled'] = true

        registry['storage']['s3'] = {
          'accesskey' => 'minioadmin',
          'secretkey' => '$MINIO_PASS_YAML',
          'bucket' => 'gitlab-registry',
          'region' => 'us-east-1',
          'regionendpoint' => 'http://minio:9000',
          'encrypt' => false,
          'secure' => false,
          'v4auth' => true,
          'chunksize' => '5242880',
          'rootdirectory' => '/registry'
        }
        registry['storage']['redirect']['disable'] = true

        unicorn['worker_processes'] = 3
        sidekiq['concurrency'] = 15

    volumes:
      - ./gitlab/config:/etc/gitlab
      - ./gitlab/logs:/var/log/gitlab
      - ./gitlab/data:/var/opt/gitlab
    networks:
      - gitlab-net

  gitlab-runner:
    image: gitlab/gitlab-runner:alpine
    restart: always
    volumes:
      - ./runner/config:/etc/gitlab-runner
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      - gitlab
    networks:
      - gitlab-net

  minio-init:
    image: minio/mc:latest
    restart: "no"
    depends_on:
      - minio
    entrypoint: >
      /bin/sh -c "
        sleep 15;
        mc alias set myminio http://minio:9000 minioadmin $MINIO_PASS_YAML;
        mc mb myminio/gitlab-lfs --ignore-existing;
        mc mb myminio/gitlab-uploads --ignore-existing;
        mc mb myminio/gitlab-artifacts --ignore-existing;
        mc mb myminio/gitlab-packages --ignore-existing;
        mc mb myminio/gitlab-registry --ignore-existing;
        mc mb myminio/gitlab-dependency-proxy --ignore-existing;
        mc mb myminio/gitlab-terraform-state --ignore-existing;
        mc mb myminio/gitlab-pages --ignore-existing;
        echo '✅ All buckets created.';
      "
    networks:
      - gitlab-net

  nginx:
    image: nginx:alpine
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
    depends_on:
      - gitlab
    networks:
      - gitlab-net

networks:
  gitlab-net:
    driver: bridge
EOF

# === 其他配置文件（略，同前）===
cat > "$GITLAB_DIR/nginx/nginx.conf" <<EOF
events {
    worker_connections 1024;
}

http {
    include /etc/nginx/proxy.conf;

    upstream gitlab {
        server gitlab:8181;
    }

    upstream registry {
        server gitlab:5000;
    }

    upstream pages {
        server gitlab:8090;
    }

    server {
        listen 443 ssl http2;
        server_name $DOMAIN;

        ssl_certificate /etc/nginx/ssl/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/privkey.pem;

        location / {
            proxy_pass http://gitlab;
            include /etc/nginx/proxy.conf;
        }
    }

    server {
        listen 443 ssl;
        server_name registry.$DOMAIN;

        ssl_certificate /etc/nginx/ssl/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/privkey.pem;

        location / {
            proxy_pass http://registry;
            include /etc/nginx/proxy.conf;
        }
    }

    server {
        listen 443 ssl;
        server_name ~^(.+)\.pages\.$DOMAIN\$;

        ssl_certificate /etc/nginx/ssl/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/privkey.pem;

        location / {
            proxy_pass http://pages;
            include /etc/nginx/proxy.conf;
        }
    }

    server {
        listen 80;
        # 内网域名
        server_name gitlab.intra;

        location / {
            proxy_pass http://gitlab;
            include /etc/nginx/proxy.conf;
        }
    }

    server {
        listen 80;
        server_name $DOMAIN registry.$DOMAIN;
        return 301 https://\$host\$request_uri;
    }

    server {
        listen 80 default_server;
        return 404;
    }
}
EOF

cat > "$GITLAB_DIR/nginx/proxy.conf" <<'EOF'
proxy_set_header Host $http_host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
client_max_body_size 1024m;
proxy_read_timeout 3600;
proxy_connect_timeout 300;
proxy_send_timeout 3600;
send_timeout 3600;
EOF

# === renew-cert.sh（略，同前）===
cat > "$GITLAB_DIR/backups/renew-cert.sh" <<'EOF'
#!/bin/bash
set -e

LOG_FILE="$HOME/gitlab/backups/cert-renew.log"
GITLAB_DIR="$HOME/gitlab"

SSL_TARGET_DIR="${GITLAB_DIR}/nginx/ssl"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

log "=== 开始执行证书续期任务 ==="

wget -O acme.sh.install https://get.acme.sh
chmod +x acme.sh.install
./acme.sh.install --install
cd ~/
~/.acme.sh/acme.sh --issue --dns dns_aliyun \
  -d waytronic.tech \
  -d '*.waytronic.tech' \
  --ecc \
  --server letsencrypt

# 安装证书到目标目录
~/.acme.sh/acme.sh --install-cert -d waytronic.tech \
  --key-file ~/gitlab/nginx/ssl/privkey.pem \
  --fullchain-file ~/gitlab/nginx/ssl/fullchain.pem  

log "=== 完成证书续期任务 ==="


mkdir -p "$SSL_TARGET_DIR"

sudo chown -R 1000:1000 "$SSL_TARGET_DIR"
sudo chmod 600 "$SSL_TARGET_DIR"/*.pem

log "✅ 证书已同步到 $SSL_TARGET_DIR"

if docker-compose -f "${GITLAB_DIR}/docker-compose.yml" ps nginx | grep -q "Up"; then
    cd "$GITLAB_DIR" && docker-compose exec -T nginx nginx -s reload
    log "✅ Nginx 容器已重载，新证书生效。"
else
    log "⚠️ Nginx 容器未运行，跳过重载。"
fi

log "=== 证书续期任务完成 ==="
EOF

chmod +x "$GITLAB_DIR/backups/renew-cert.sh"

# 设置权限
sudo chown -R 1000:1000 "$GITLAB_DIR"

log "✅ 部署模板生成完成！"

# === 使用说明 ===
cat <<FINAL

🎉 GitLab 已初始化！密码已自动生成并保存至：
   $SECRETS_FILE

📌 下一步操作：

1. **申请泛域名证书**（首次）：
   

2. **复制证书**
   sudo chown 1000:1000 $GITLAB_DIR/nginx/ssl/*.pem

3. **启动服务**
   cd $GITLAB_DIR
   docker compose up -d

4. **设置自动续期**
   crontab -e
   # 添加：
   0 2 1 */2 * $GITLAB_DIR/backups/renew-cert.sh >> $GITLAB_DIR/backups/cert-renew.log 2>&1

💡 提示：首次启动需 5~10 分钟，请耐心等待。
FINAL