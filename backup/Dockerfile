ARG MYSQL_VERSION=8.0.45
FROM mysql:${MYSQL_VERSION}

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
      x86_64) aws_arch="x86_64" ;; \
      aarch64|arm64) aws_arch="aarch64" ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o /tmp/awscliv2.zip; \
    unzip /tmp/awscliv2.zip -d /tmp; \
    /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli; \
    rm -rf /tmp/aws /tmp/awscliv2.zip

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/backup.sh /usr/local/bin/backup.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
