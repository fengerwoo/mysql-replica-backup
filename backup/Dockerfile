ARG MYSQL_VERSION=8.0.45
FROM mysql:${MYSQL_VERSION}

ARG OSSUTIL_VERSION=1.7.19

RUN set -eux; \
    if command -v microdnf >/dev/null 2>&1; then \
      microdnf install -y ca-certificates curl gzip tzdata unzip && microdnf clean all; \
    elif command -v yum >/dev/null 2>&1; then \
      yum install -y ca-certificates curl gzip tzdata unzip && yum clean all; \
    elif command -v apt-get >/dev/null 2>&1; then \
      apt-get update; \
      apt-get install -y --no-install-recommends ca-certificates curl gzip tzdata unzip; \
      rm -rf /var/lib/apt/lists/*; \
    else \
      echo "No supported package manager found" >&2; \
      exit 1; \
    fi; \
    case "$(uname -m)" in \
      x86_64) oss_arch="amd64" ;; \
      aarch64|arm64) oss_arch="arm64" ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://gosspublic.alicdn.com/ossutil/${OSSUTIL_VERSION}/ossutil-v${OSSUTIL_VERSION}-linux-${oss_arch}.zip" -o /tmp/ossutil.zip; \
    mkdir -p /tmp/ossutil; \
    unzip /tmp/ossutil.zip -d /tmp/ossutil; \
    find /tmp/ossutil -type f -name ossutil -exec install -m 0755 {} /usr/local/bin/ossutil \;; \
    rm -rf /tmp/ossutil /tmp/ossutil.zip

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/backup.sh /usr/local/bin/backup.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
