FROM python:3.11-slim

WORKDIR /app

# Install any custom CA certificates before making network requests.
# Drop .crt files into the certs/ directory (gitignored) to have them trusted at build time.
# Useful for corporate TLS inspection proxies (e.g. Zscaler).
COPY certs/ /usr/local/share/ca-certificates/
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2 (needed for EKS kubeconfig credential helper)
RUN curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip \
    && unzip -q awscliv2.zip \
    && ./aws/install \
    && rm -rf aws awscliv2.zip

# Install kubectl (pinned version, direct from Google CDN to avoid dl.k8s.io SSL issues)
ARG KUBECTL_VERSION=v1.31.0
RUN curl -sLO "https://storage.googleapis.com/kubernetes-release/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm kubectl

# Install helm from the official release mirror
ARG HELM_VERSION=v3.16.3
RUN curl -sL -o helm.tar.gz "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    && tar xzf helm.tar.gz \
    && install -o root -g root -m 0755 linux-amd64/helm /usr/local/bin/helm \
    && rm -rf linux-amd64 helm.tar.gz \
    && helm version --short

# Ensure /usr/local/bin is in PATH for subprocess execution
ENV PATH="/usr/local/bin:${PATH}"

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Expose port
EXPOSE 8080

# Run the application
CMD ["python", "app.py"]
