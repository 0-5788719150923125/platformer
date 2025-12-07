[Unit]
Description=Atlantis Terraform Automation
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=always
RestartSec=10

# Clean up any existing container
ExecStartPre=-/usr/bin/docker stop atlantis
ExecStartPre=-/usr/bin/docker rm atlantis

# Start Atlantis via wrapper script (avoids all shell escaping issues)
ExecStart=/usr/local/bin/start-atlantis.sh ${atlantis_port} ${region} ${atlantis_repo_allowlist}

# Stop container on service stop
ExecStop=/usr/bin/docker stop atlantis

[Install]
WantedBy=multi-user.target
