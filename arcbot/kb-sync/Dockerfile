FROM python:3.12-slim
# git enumerates tracked files in the mounted checkouts; they're owned by the
# host user, so mark every directory safe for the container's root user.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/* \
    && git config --system --add safe.directory '*'
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py .
ENTRYPOINT ["python", "-u", "main.py"]
