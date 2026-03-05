FROM docker.io/amazon/aws-cli:latest

# Install baseline tools, Namecheap API helpers, Node.js + npm, Codex CLI, and Terraform via official binary
ARG TERRAFORM_VERSION=1.7.5
RUN set -eux; \
    if command -v dnf >/dev/null 2>&1; then \
      dnf install -y unzip zip jq nodejs npm openssh-clients python3 tar; \
      dnf clean all; \
    elif command -v yum >/dev/null 2>&1; then \
      yum install -y unzip zip jq nodejs npm openssh-clients python3 tar; \
      yum clean all; \
    elif command -v apk >/dev/null 2>&1; then \
      apk add --no-cache unzip zip jq nodejs npm openssh-client curl python3 py3-pip tar; \
    else \
      echo "No supported package manager found (dnf/yum/apk)"; exit 1; \
    fi; \
    npm install -g @openai/codex; \
    codex --version || true; \
    curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip; \
    unzip -q /tmp/terraform.zip -d /usr/local/bin; \
    chmod +x /usr/local/bin/terraform; \
    rm -f /tmp/terraform.zip; \
    terraform -version

# Start an interactive shell by default
CMD ["/bin/bash"]
