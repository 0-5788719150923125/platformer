# ClaireVoyance

Medical AI inference platform on AWS SageMaker.

## Documentation

Full documentation in upstream repository: [hackathon-8/improve-compat](https://github.com/acme-sandbox/hackathon-8/tree/improve-compat)

Includes architecture, model descriptions (MedGemma, CheXagent, MedSAM2, Classifier), configuration options, cost estimation, and troubleshooting.

## Prerequisites

Must exist before deployment:

1. **Route53 Hosted Zone** - `dev-platform.example.com` (exists in example-platform-dev)
2. **HuggingFace API Token** - Create in Secrets Manager as `huggingface` with format `{"HF_TOKEN":"..."}`
3. **VPC with Public Subnets** - At least 2 public subnets in standard AZs

## Known Limitations

- **Cannot use `count` or `for_each`** - Module contains provider blocks
- **Route53 zone required** - Fails if hosted zone doesn't exist
- **HuggingFace secret must be pre-created** - Manual setup before first plan

## Version Pinning

Currently using `improve-compat` branch. For production, pin to specific commit.
