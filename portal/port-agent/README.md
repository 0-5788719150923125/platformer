# Port Agent Setup

Docker Compose configuration for Port.io execution agent and custom action handler.

## Overview

This directory contains the Docker Compose setup for running Port.io self-service actions locally:

- **port-agent** - Official Port.io execution agent (polls for action invocations)
- **action-handler** - Custom Flask app that executes commands via AWS SSM

## Architecture

```
Port UI (app.us.getport.io)
    |
    | (POLLING or Kafka)
    v
port-agent container
    |
    | (HTTP webhook)
    v
action-handler container
    |
    | (AWS SSM)
    v
EC2 instances
```

## Environment Variables

### Port Agent (ghcr.io/port-labs/port-agent:latest)

**Required via .env file:**
- `PORT_ORG_ID` - Your Port organization ID
- `PORT_CLIENT_ID` - Port API client ID
- `PORT_CLIENT_SECRET` - Port API client secret

**Set in compose.yml:**
- `PORT_API_BASE_URL` - Port API endpoint (⚠️ Must be `PORT_API_BASE_URL`, not `PORT_BASE_URL`)
  - US region: `https://api.us.getport.io`
  - EU region: `https://api.getport.io`
- `STREAMER_NAME` - `POLLING` (simpler) or `KAFKA` (requires additional config)

### Action Handler (custom Python Flask app)

**Required via .env file:**
- `PORT_CLIENT_ID` - Port API client ID (for log streaming)
- `PORT_CLIENT_SECRET` - Port API client secret

**Set in compose.yml:**
- `PORT_BASE_URL` - Port API endpoint (our custom code, can use either name)
- `AWS_PROFILE` - AWS profile for SSO authentication
- `AWS_REGION` - AWS region for SSM commands
- `NAMESPACE` - Platformer namespace for filtering entities

**Mounted volumes:**
- `~/.aws:/root/.aws:ro` - AWS SSO credentials (read-only)

## Region Configuration

Port has two API regions:

| Region | App URL | API URL |
|--------|---------|---------|
| US | https://app.us.getport.io | https://api.us.getport.io |
| EU | https://app.port.io | https://api.port.io |

**Important:** The port-agent uses `PORT_API_BASE_URL` (not `PORT_BASE_URL`) to configure the API endpoint. This is documented in the [official Port agent installation guide](https://docs.port.io/actions-and-automations/setup-backend/webhook/port-execution-agent/installation-methods/docker/).

## Lifecycle Management

Services are managed via Terraform:

```bash
# Start services (via Terraform)
terraform apply

# Stop services (via Terraform)
terraform destroy

# Manual management (for testing)
cd /home/rybrooks/infra-terraform/platformer/portal/port-agent
NAMESPACE=qurorary docker compose up -d    # Start
docker compose logs -f                      # View logs
docker compose down                         # Stop
```

## Troubleshooting

### Port agent shows 401 Unauthorized

**Symptom:**
```
ERROR:port_client:Failed to get Port API access token - status: 401
ERROR:consumers.http_polling_consumer:Error during HTTP polling: 401 Client Error: Unauthorized for url: https://api.getport.io/v1/auth/access_token
```

**Causes:**
1. Wrong API endpoint (connecting to EU instead of US or vice versa)
2. Invalid credentials
3. Using `PORT_BASE_URL` instead of `PORT_API_BASE_URL`

**Fix:**
```bash
# Check environment variables
docker exec platformer-port-agent-{namespace} env | grep PORT

# Should show:
# PORT_API_BASE_URL=https://api.us.getport.io  (or https://api.getport.io for EU)
# PORT_CLIENT_ID=...
# PORT_CLIENT_SECRET=...
# PORT_ORG_ID=...

# If PORT_API_BASE_URL is missing, update compose.yml and recreate containers
docker compose down
docker compose up -d
```

### Action handler missing credentials

**Symptom:**
```
PORT_CLIENT_ID and PORT_CLIENT_SECRET must be set
```

**Fix:**
Ensure `.env` file exists with credentials when starting services. The Terraform script handles this automatically.

### AWS SSO authentication failed

**Symptom:**
```
Error: Unable to locate credentials
```

**Fix:**
```bash
# Re-authenticate with AWS SSO
aws sso login --profile example-platform-dev

# Verify credentials
aws sts get-caller-identity --profile example-platform-dev
```

### SSM command execution failed

**Symptom:**
```
❌ Failed to send command: An error occurred (InvalidInstanceId) when calling the SendCommand operation
```

**Causes:**
1. EC2 instance doesn't have SSM agent installed
2. Instance IAM role missing `AmazonSSMManagedInstanceCore` policy
3. Instance not registered with SSM

**Fix:**
```bash
# Check SSM agent status on instance
aws ssm describe-instance-information \
  --profile example-platform-dev \
  --region us-east-2 \
  --filters "Key=InstanceIds,Values=i-xxxxx"

# If instance not listed, SSM agent needs to be installed/configured
```

## Development

### Testing Locally

1. Create test .env file:
```bash
cat > .env << EOF
PORT_ORG_ID=org_xxxxx
PORT_CLIENT_ID=xxxxx
PORT_CLIENT_SECRET=xxxxx
EOF
chmod 600 .env
```

2. Start services:
```bash
NAMESPACE=test AWS_PROFILE=example-platform-dev docker compose up -d
```

3. View logs:
```bash
docker compose logs -f port-agent      # Port agent logs
docker compose logs -f action-handler  # Action handler logs
```

4. Test webhook endpoint:
```bash
curl -X POST http://localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "entity": {
      "properties": {
        "awsInstanceId": "i-xxxxx"
      }
    },
    "payload": {
      "properties": {
        "command": "echo hello"
      }
    },
    "context": {
      "runId": "test-run-123"
    }
  }'
```

5. Clean up:
```bash
docker compose down
rm .env
```

## Action Definition

The "Run Command" action is defined in `action-definition.json` and managed via Terraform:

- **Type:** DAY-2 (operates on existing entities)
- **Blueprint:** computeInstance
- **Method:** WEBHOOK with agent=true
- **Endpoint:** http://action-handler:8080/webhook (Docker network)

## References

- [Port Execution Agent Documentation](https://docs.port.io/actions-and-automations/setup-backend/webhook/port-execution-agent/)
- [Port API Region Selection](https://docs.port.io/build-your-software-catalog/custom-integration/api/#selecting-a-port-api-url-by-account-region)
- [AWS Systems Manager (SSM)](https://docs.aws.amazon.com/systems-manager/latest/userguide/what-is-systems-manager.html)
