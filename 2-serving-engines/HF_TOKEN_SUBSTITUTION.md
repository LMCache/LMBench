# HuggingFace Token Substitution

## Overview

Both production stacks (Helm and Direct) support automatic HuggingFace token substitution to securely inject authentication tokens without hardcoding credentials in configuration files.

## Quick Setup

```bash
# Set your HuggingFace token
export HF_TOKEN="your_actual_huggingface_token_here"

# Deploy using either stack
./choose-and-deploy.sh <config_name>
```

## How It Works

### Placeholders
- **`<YOUR_HF_TOKEN>`** - Replaced with raw token (used in Helm stack)
- **`<YOUR_HF_TOKEN_BASE64>`** - Replaced with base64-encoded token (used in Direct stack)

### Processing
1. Scripts validate `HF_TOKEN` environment variable exists
2. Placeholders in configuration files are substituted at deployment time
3. Processed configurations are applied to Kubernetes

## Stack-Specific Details

### Helm Production Stack
- **Script**: `helm-production-stack/choose-and-deploy.sh`
- **Placeholder**: `<YOUR_HF_TOKEN>`
- **Files**: All YAML files in `helm_configurations/`

### Direct Production Stack
- **Script**: `direct-production-stack/choose-and-deploy.sh`
- **Placeholders**: `<YOUR_HF_TOKEN>` and `<YOUR_HF_TOKEN_BASE64>`
- **Files**: All YAML files in `kubernetes_configurations/`

## Error Handling

Both scripts will exit with an error if `HF_TOKEN` is not set:
```bash
Error: HF_TOKEN environment variable is not set
```

## Troubleshooting

### 401 Unauthorized Errors
1. Verify token is set: `echo $HF_TOKEN`
2. Ensure token has model access permissions
3. Check token format (should start with `hf_`)

### Token Not Substituted
1. Confirm `HF_TOKEN` is exported before deployment
2. Verify placeholder format matches exactly
3. Check deployment script completed without errors

## Security Benefits

- No hardcoded tokens in version control
- Runtime-only token injection
- Environment-specific token management
- Automatic base64 encoding for Kubernetes secrets