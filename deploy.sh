#!/bin/bash
set -euo pipefail

#######################################################################
# SoftEther VPN + Wazuh Deployment Script
# Deploys the VPC and then the selected SoftEther template via CloudFormation
#######################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="us-east-1"
VPC_STACK_NAME="softether-vpc"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
  if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is not installed. Please install it first."
    exit 1
  fi

  if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS CLI is not configured or credentials are invalid."
    exit 1
  fi

  print_info "AWS CLI configured. Account: $(aws sts get-caller-identity --query Account --output text)"
  print_info "Region: $REGION"
}

# Prompt for a value with optional default
prompt() {
  local var_name="$1"
  local prompt_text="$2"
  local default="${3:-}"
  local secret="${4:-false}"

  if [ -n "$default" ]; then
    prompt_text="$prompt_text [$default]"
  fi

  if [ "$secret" = "true" ]; then
    read -s -p "$prompt_text: " value
    echo ""
  else
    read -p "$prompt_text: " value
  fi

  value="${value:-$default}"

  if [ -z "$value" ]; then
    print_error "$var_name cannot be empty."
    exit 1
  fi

  printf -v "$var_name" '%s' "$value"
}

# Validate password meets CloudFormation pattern requirements
validate_password() {
  local password="$1"
  local field_name="$2"

  if [ ${#password} -lt 8 ] || [ ${#password} -gt 64 ]; then
    print_error "$field_name must be between 8 and 64 characters."
    return 1
  fi
  if ! echo "$password" | grep -q '[a-z]'; then
    print_error "$field_name must contain at least one lowercase letter."
    return 1
  fi
  if ! echo "$password" | grep -q '[A-Z]'; then
    print_error "$field_name must contain at least one uppercase letter."
    return 1
  fi
  if ! echo "$password" | grep -q '[0-9]'; then
    print_error "$field_name must contain at least one number."
    return 1
  fi
  if ! echo "$password" | grep -q '[.*+?-]'; then
    print_error "$field_name must contain at least one of these symbols: . * + ? -"
    return 1
  fi
  return 0
}

# Prompt for a password with validation (retries until valid)
prompt_password() {
  local var_name="$1"
  local prompt_text="$2"

  while true; do
    read -s -p "$prompt_text: " value
    echo ""
    if [ -z "$value" ]; then
      print_error "$var_name cannot be empty."
      continue
    fi
    if validate_password "$value" "$var_name"; then
      break
    fi
    print_warn "Please try again."
  done

  printf -v "$var_name" '%s' "$value"
}

# Validate instance type is available in the given AZ
validate_instance_type_az() {
  local instance_type="$1"
  local az="$2"
  local available
  available=$(aws ec2 describe-instance-type-offerings \
    --location-type availability-zone \
    --filters "Name=instance-type,Values=$instance_type" "Name=location,Values=$az" \
    --region "$REGION" --query "InstanceTypeOfferings[0].InstanceType" --output text 2>/dev/null)
  if [ "$available" = "None" ] || [ -z "$available" ]; then
    return 1
  fi
  return 0
}

# Prompt for Wazuh version from allowed list
prompt_wazuh_version() {
  echo ""
  echo "  Available Wazuh versions:"
  echo "    1) 4.14 (latest)"
  echo "    2) 4.13"
  echo "    3) 4.12"
  echo "    4) 4.11"
  echo "    5) 4.10"
  echo "    6) 4.9"
  echo ""
  read -p "  Select Wazuh version [1]: " wv_choice
  wv_choice="${wv_choice:-1}"
  case "$wv_choice" in
    1) WAZUH_VERSION="4.14" ;;
    2) WAZUH_VERSION="4.13" ;;
    3) WAZUH_VERSION="4.12" ;;
    4) WAZUH_VERSION="4.11" ;;
    5) WAZUH_VERSION="4.10" ;;
    6) WAZUH_VERSION="4.9" ;;
    *) WAZUH_VERSION="4.14" ;;
  esac
  print_info "Wazuh version: $WAZUH_VERSION"
}

# Prompt for SoftEther version from allowed list
prompt_softether_version() {
  echo ""
  echo "  Available SoftEther versions:"
  echo "    1) v4.44-9807-rtm (latest, 2025.04.16)"
  echo "    2) v4.42-9798-rtm (2023.06.30)"
  echo "    3) v4.41-9787-rtm (2023.03.14)"
  echo "    4) v4.38-9760-rtm (2021.08.17)"
  echo ""
  read -p "  Select SoftEther version [1]: " sv_choice
  sv_choice="${sv_choice:-1}"
  case "$sv_choice" in
    1) SOFTETHER_URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.44-9807-rtm/softether-vpnserver-v4.44-9807-rtm-2025.04.16-linux-x64-64bit.tar.gz" ;;
    2) SOFTETHER_URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.42-9798-rtm/softether-vpnserver-v4.42-9798-rtm-2023.06.30-linux-x64-64bit.tar.gz" ;;
    3) SOFTETHER_URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.41-9787-rtm/softether-vpnserver-v4.41-9787-rtm-2023.03.14-linux-x64-64bit.tar.gz" ;;
    4) SOFTETHER_URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.38-9760-rtm/softether-vpnserver-v4.38-9760-rtm-2021.08.17-linux-x64-64bit.tar.gz" ;;
    *) SOFTETHER_URL="https://github.com/SoftEtherVPN/SoftEtherVPN_Stable/releases/download/v4.44-9807-rtm/softether-vpnserver-v4.44-9807-rtm-2025.04.16-linux-x64-64bit.tar.gz" ;;
  esac
  print_info "SoftEther URL: $SOFTETHER_URL"
}

# Wait for stack to complete
wait_for_stack() {
  local stack_name="$1"
  local operation="$2"

  print_info "Waiting for stack '$stack_name' to complete ($operation)..."

  if aws cloudformation wait "stack-${operation}-complete" \
    --stack-name "$stack_name" \
    --region "$REGION" 2>/dev/null; then
    print_info "Stack '$stack_name' $operation completed successfully."
  else
    print_error "Stack '$stack_name' $operation failed."
    # Show stack status reason (useful for validation errors)
    aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" \
      --query "Stacks[0].StackStatusReason" --output text 2>/dev/null || true
    # Show failed resource events
    aws cloudformation describe-stack-events \
      --stack-name "$stack_name" \
      --region "$REGION" \
      --query "StackEvents[?ResourceStatus=='CREATE_FAILED' || ResourceStatus=='ROLLBACK_IN_PROGRESS'].[LogicalResourceId,ResourceStatusReason]" \
      --output table 2>/dev/null || true
    exit 1
  fi
}

# Deploy or use existing VPC
setup_vpc() {
  echo ""
  echo "  VPC Configuration:"
  echo ""
  echo "    1) Create a new VPC (using vpc.yml)"
  echo "    2) Use an existing VPC"
  echo ""
  read -p "  Select [1]: " vpc_choice
  vpc_choice="${vpc_choice:-1}"

  if [ "$vpc_choice" = "2" ]; then
    prompt VPC_ID "VPC ID (e.g. vpc-0abc123)"
    prompt PUBLIC_SUBNET_1 "Public Subnet 1 ID (for SoftEther or NLB)"
    prompt PUBLIC_SUBNET_2 "Public Subnet 2 ID (for NLB, or same as Subnet 1 if not using NLB)"
    prompt PRIVATE_SUBNET_1 "Private Subnet 1 ID (for Wazuh or SoftEther in external mode)"
    prompt PRIVATE_SUBNET_2 "Private Subnet 2 ID (optional, press enter to reuse Subnet 1)" "$PRIVATE_SUBNET_1"
    prompt PRIVATE_NETWORK_CIDR "Private network CIDR to route through VPN (e.g. 172.16.1.0/24)" "10.0.3.0/24"
    print_info "Using existing VPC: $VPC_ID"
  else
    deploy_vpc
    PRIVATE_NETWORK_CIDR="10.0.3.0/24"
  fi
}

# Deploy VPC stack
deploy_vpc() {
  print_info "=== Deploying VPC ==="

  if aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" --region "$REGION" &> /dev/null; then
    print_warn "VPC stack '$VPC_STACK_NAME' already exists. Skipping VPC deployment."
  else
    aws cloudformation create-stack \
      --stack-name "$VPC_STACK_NAME" \
      --template-body "file://${SCRIPT_DIR}/vpc.yml" \
      --region "$REGION" \
      --tags Key=Project,Value=SoftEther-Wazuh

    wait_for_stack "$VPC_STACK_NAME" "create"
  fi

  # Retrieve VPC outputs
  VPC_ID=$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='VPCId'].OutputValue" --output text)
  PUBLIC_SUBNET_1=$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet1Id'].OutputValue" --output text)
  PUBLIC_SUBNET_2=$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='PublicSubnet2Id'].OutputValue" --output text)
  PRIVATE_SUBNET_1=$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet1Id'].OutputValue" --output text)
  PRIVATE_SUBNET_2=$(aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet2Id'].OutputValue" --output text)

  print_info "VPC ID: $VPC_ID"
  print_info "Public Subnet 1: $PUBLIC_SUBNET_1"
  print_info "Public Subnet 2: $PUBLIC_SUBNET_2"
  print_info "Private Subnet 1: $PRIVATE_SUBNET_1"
  print_info "Private Subnet 2: $PRIVATE_SUBNET_2"
}

# Deploy SoftEther + Wazuh (internal mode)
deploy_internal() {
  local stack_name="softether-internal"
  print_info "=== Deploying SoftEther + Wazuh (Internal with EIP) ==="

  # Auto-detect AZs from subnets (ensures volumes match instances)
  SOFTETHER_AZ=$(aws ec2 describe-subnets --subnet-ids "$PUBLIC_SUBNET_1" --region "$REGION" \
    --query "Subnets[0].AvailabilityZone" --output text)
  WAZUH_AZ=$(aws ec2 describe-subnets --subnet-ids "$PRIVATE_SUBNET_1" --region "$REGION" \
    --query "Subnets[0].AvailabilityZone" --output text)
  print_info "SoftEther AZ (from subnet): $SOFTETHER_AZ"
  print_info "Wazuh AZ (from subnet): $WAZUH_AZ"

  prompt HUB_NAME "VPN Hub name" "VPN"
  prompt_password SOFTETHER_PASSWORD "SoftEther admin password"
  prompt_password WAZUH_PASSWORD "Wazuh admin password"
  prompt IPSEC_PSK "IPsec pre-shared key" "" true
  prompt DEFAULT_VPN_USER "Default VPN username"
  prompt_password DEFAULT_VPN_USER_PASSWORD "Default VPN user password"

  # Prompt for instance type with AZ availability validation (retry loop)
  while true; do
    prompt INSTANCE_TYPE "EC2 instance type" "t3a.medium"
    local az_fail=""
    for check_az in "$SOFTETHER_AZ" "$WAZUH_AZ"; do
      if ! validate_instance_type_az "$INSTANCE_TYPE" "$check_az"; then
        az_fail="$check_az"
        break
      fi
    done
    if [ -n "$az_fail" ]; then
      print_error "Instance type '$INSTANCE_TYPE' is not available in $az_fail."
      print_info "AZs where '$INSTANCE_TYPE' is available:"
      aws ec2 describe-instance-type-offerings \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --region "$REGION" --query "InstanceTypeOfferings[].Location" \
        --output text 2>/dev/null | tr '\t' '\n' | sort
      echo ""
      echo "  Options:"
      echo "    1) Enter a different instance type"
      echo "    2) Change subnets (re-enter subnet IDs)"
      echo ""
      read -p "  Select [1]: " fix_choice
      fix_choice="${fix_choice:-1}"
      if [ "$fix_choice" = "2" ]; then
        prompt PUBLIC_SUBNET_1 "Public Subnet 1 ID (for SoftEther)"
        prompt PRIVATE_SUBNET_1 "Private Subnet 1 ID (for Wazuh)"
        SOFTETHER_AZ=$(aws ec2 describe-subnets --subnet-ids "$PUBLIC_SUBNET_1" --region "$REGION" \
          --query "Subnets[0].AvailabilityZone" --output text)
        WAZUH_AZ=$(aws ec2 describe-subnets --subnet-ids "$PRIVATE_SUBNET_1" --region "$REGION" \
          --query "Subnets[0].AvailabilityZone" --output text)
        print_info "New SoftEther AZ: $SOFTETHER_AZ"
        print_info "New Wazuh AZ: $WAZUH_AZ"
      fi
      # Loop back to re-prompt instance type
    else
      break
    fi
  done

  prompt_softether_version
  prompt_wazuh_version

  # Write parameters to a temporary JSON file to avoid shell escaping issues
  local params_file
  params_file=$(mktemp)
  cat > "$params_file" << JSONEOF
[
  {"ParameterKey": "DeploymentMode", "ParameterValue": "internal"},
  {"ParameterKey": "SoftetherAvailabilityZone", "ParameterValue": "${SOFTETHER_AZ}"},
  {"ParameterKey": "WazuhAvailabilityZone", "ParameterValue": "${WAZUH_AZ}"},
  {"ParameterKey": "NameBurtualHubVPN", "ParameterValue": "${HUB_NAME}"},
  {"ParameterKey": "SoftetherPassword", "ParameterValue": $(printf '%s' "$SOFTETHER_PASSWORD" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')},
  {"ParameterKey": "WazuhPassword", "ParameterValue": $(printf '%s' "$WAZUH_PASSWORD" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')},
  {"ParameterKey": "WazuhVersion", "ParameterValue": "${WAZUH_VERSION}"},
  {"ParameterKey": "IPsecPreSharedKey", "ParameterValue": $(printf '%s' "$IPSEC_PSK" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')},
  {"ParameterKey": "DefaultVPNUser", "ParameterValue": "${DEFAULT_VPN_USER}"},
  {"ParameterKey": "DefaultVPNUserPassword", "ParameterValue": $(printf '%s' "$DEFAULT_VPN_USER_PASSWORD" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')},
  {"ParameterKey": "EC2InstanceType", "ParameterValue": "${INSTANCE_TYPE}"},
  {"ParameterKey": "SoftetherDownloadUrl", "ParameterValue": "${SOFTETHER_URL}"},
  {"ParameterKey": "SubnetIdSoftether", "ParameterValue": "${PUBLIC_SUBNET_1}"},
  {"ParameterKey": "SubnetIdPrivateWazuh", "ParameterValue": "${PRIVATE_SUBNET_1}"},
  {"ParameterKey": "PrivateNetworkCIDR", "ParameterValue": "${PRIVATE_NETWORK_CIDR}"},
  {"ParameterKey": "VPCId", "ParameterValue": "${VPC_ID}"}
]
JSONEOF

  aws cloudformation create-stack \
    --stack-name "$stack_name" \
    --template-body "file://${SCRIPT_DIR}/Softether_wazuh.yml" \
    --region "$REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Project,Value=SoftEther-Wazuh \
    --parameters "file://${params_file}"

  rm -f "$params_file"
  wait_for_stack "$stack_name" "create"
  print_outputs "$stack_name"
}

# Deploy SoftEther + Wazuh (external mode with NLB)
deploy_external() {
  local stack_name="softether-external"
  print_info "=== Deploying SoftEther + Wazuh (External with NLB + TLS) ==="

  # Auto-detect AZs from subnets (ensures volumes match instances)
  SOFTETHER_AZ=$(aws ec2 describe-subnets --subnet-ids "$PRIVATE_SUBNET_1" --region "$REGION" \
    --query "Subnets[0].AvailabilityZone" --output text)
  WAZUH_AZ="$SOFTETHER_AZ"
  print_info "Availability Zone (from subnet): $SOFTETHER_AZ"

  prompt HUB_NAME "VPN Hub name" "VPN"
  prompt_password SOFTETHER_PASSWORD "SoftEther admin password"
  prompt_password WAZUH_PASSWORD "Wazuh admin password"
  prompt IPSEC_PSK "IPsec pre-shared key" "" true
  prompt DEFAULT_VPN_USER "Default VPN username"
  prompt_password DEFAULT_VPN_USER_PASSWORD "Default VPN user password"
  prompt DOMAIN_NAME "VPN domain name (e.g. vpn.example.com)"
  prompt HOSTED_ZONE_ID "Route 53 Hosted Zone ID"

  # Prompt for instance type with AZ availability validation (retry loop)
  while true; do
    prompt INSTANCE_TYPE "EC2 instance type" "t3a.medium"
    if ! validate_instance_type_az "$INSTANCE_TYPE" "$SOFTETHER_AZ"; then
      print_error "Instance type '$INSTANCE_TYPE' is not available in $SOFTETHER_AZ."
      print_info "AZs where '$INSTANCE_TYPE' is available:"
      aws ec2 describe-instance-type-offerings \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --region "$REGION" --query "InstanceTypeOfferings[].Location" \
        --output text 2>/dev/null | tr '\t' '\n' | sort
      echo ""
      echo "  Options:"
      echo "    1) Enter a different instance type"
      echo "    2) Change private subnet (re-enter subnet ID)"
      echo ""
      read -p "  Select [1]: " fix_choice
      fix_choice="${fix_choice:-1}"
      if [ "$fix_choice" = "2" ]; then
        prompt PRIVATE_SUBNET_1 "Private Subnet 1 ID (for SoftEther and Wazuh)"
        SOFTETHER_AZ=$(aws ec2 describe-subnets --subnet-ids "$PRIVATE_SUBNET_1" --region "$REGION" \
          --query "Subnets[0].AvailabilityZone" --output text)
        WAZUH_AZ="$SOFTETHER_AZ"
        print_info "New AZ: $SOFTETHER_AZ"
      fi
    else
      break
    fi
  done

  prompt_softether_version
  prompt_wazuh_version

  # Write parameters to a temporary JSON file to avoid shell escaping issues
  local params_file
  params_file=$(mktemp)
  cat > "$params_file" << JSONEOF
[
  {"ParameterKey": "DeploymentMode", "ParameterValue": "external"},
  {"ParameterKey": "SoftetherAvailabilityZone", "ParameterValue": "${SOFTETHER_AZ}"},
  {"ParameterKey": "WazuhAvailabilityZone", "ParameterValue": "${WAZUH_AZ}"},
  {"ParameterKey": "NameBurtualHubVPN", "ParameterValue": "${HUB_NAME}"},
  {"ParameterKey": "SoftetherPassword", "ParameterValue": $(printf '%s' "$SOFTETHER_PASSWORD" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')},
  {"ParameterKey": "WazuhPassword", "ParameterValue": $(printf '%s' "$WAZUH_PASSWORD" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')},
  {"ParameterKey": "WazuhVersion", "ParameterValue": "${WAZUH_VERSION}"},
  {"ParameterKey": "IPsecPreSharedKey", "ParameterValue": $(printf '%s' "$IPSEC_PSK" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')},
  {"ParameterKey": "DefaultVPNUser", "ParameterValue": "${DEFAULT_VPN_USER}"},
  {"ParameterKey": "DefaultVPNUserPassword", "ParameterValue": $(printf '%s' "$DEFAULT_VPN_USER_PASSWORD" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')},
  {"ParameterKey": "DomainName", "ParameterValue": "${DOMAIN_NAME}"},
  {"ParameterKey": "HostedZoneId", "ParameterValue": "${HOSTED_ZONE_ID}"},
  {"ParameterKey": "EC2InstanceType", "ParameterValue": "${INSTANCE_TYPE}"},
  {"ParameterKey": "SoftetherDownloadUrl", "ParameterValue": "${SOFTETHER_URL}"},
  {"ParameterKey": "SubnetIdSoftether", "ParameterValue": "${PRIVATE_SUBNET_1}"},
  {"ParameterKey": "SubnetIdPrivateWazuh", "ParameterValue": "${PRIVATE_SUBNET_1}"},
  {"ParameterKey": "PrivateNetworkCIDR", "ParameterValue": "${PRIVATE_NETWORK_CIDR}"},
  {"ParameterKey": "SubnetIdPublicOne", "ParameterValue": "${PUBLIC_SUBNET_1}"},
  {"ParameterKey": "SubnetIdPublicTwo", "ParameterValue": "${PUBLIC_SUBNET_2}"},
  {"ParameterKey": "VPCId", "ParameterValue": "${VPC_ID}"}
]
JSONEOF

  aws cloudformation create-stack \
    --stack-name "$stack_name" \
    --template-body "file://${SCRIPT_DIR}/Softether_wazuh.yml" \
    --region "$REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Project,Value=SoftEther-Wazuh \
    --parameters "file://${params_file}"

  rm -f "$params_file"
  wait_for_stack "$stack_name" "create"
  print_outputs "$stack_name"
}

# Print stack outputs
print_outputs() {
  local stack_name="$1"
  echo ""
  print_info "=== Stack Outputs ==="
  aws cloudformation describe-stacks \
    --stack-name "$stack_name" \
    --region "$REGION" \
    --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" \
    --output table
}

# Destroy stacks
destroy() {
  print_warn "=== Destroying Stacks ==="
  echo "This will delete the following stacks (EBS config volumes are retained):"
  echo "  - softether-internal"
  echo "  - softether-external"
  echo "  - softether-vpc"
  echo ""
  read -p "Are you sure? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    print_info "Aborted."
    exit 0
  fi

  for stack in softether-internal softether-external; do
    if aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" &> /dev/null; then
      # Empty the flow logs S3 bucket before deleting the stack
      BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='FlowLogsBucketName'].OutputValue" --output text 2>/dev/null)
      if [ -n "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ] && [ "$BUCKET_NAME" != "null" ]; then
        print_info "Emptying S3 bucket: $BUCKET_NAME"
        aws s3 rb "s3://${BUCKET_NAME}" --force --region "$REGION" 2>/dev/null || true
      fi
      print_info "Deleting stack: $stack"
      aws cloudformation delete-stack --stack-name "$stack" --region "$REGION"
      aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$REGION"
      print_info "Stack '$stack' deleted."
    fi
  done

  if aws cloudformation describe-stacks --stack-name "$VPC_STACK_NAME" --region "$REGION" &> /dev/null; then
    print_info "Deleting VPC stack: $VPC_STACK_NAME"
    aws cloudformation delete-stack --stack-name "$VPC_STACK_NAME" --region "$REGION"
    aws cloudformation wait stack-delete-complete --stack-name "$VPC_STACK_NAME" --region "$REGION"
    print_info "VPC stack deleted."
  fi

  print_info "All stacks destroyed. Note: EBS config volumes (Softether-Config, Wazuh-Config) are retained."
}

# Main menu
main() {
  echo ""
  echo "╔═══════════════════════════════════════════════════════════╗"
  echo "║       SoftEther VPN + Wazuh — AWS Deployment Tool        ║"
  echo "╚═══════════════════════════════════════════════════════════╝"
  echo ""
  echo "  Deployment options:"
  echo ""
  echo "    1) Internal — SoftEther + Wazuh (Elastic IP, direct access)"
  echo "    2) External — SoftEther + Wazuh (NLB + TLS + Route 53)"
  echo ""
  echo "  Management:"
  echo ""
  echo "    3) Destroy all stacks"
  echo "    4) Exit"
  echo ""
  read -p "Option [1-4]: " choice

  if [ "$choice" != "3" ] && [ "$choice" != "4" ]; then
    prompt REGION "AWS Region" "us-east-1"
  fi

  check_prerequisites

  case "$choice" in
    1)
      setup_vpc
      deploy_internal
      ;;
    2)
      setup_vpc
      deploy_external
      ;;
    3)
      destroy
      ;;
    4)
      print_info "Bye."
      exit 0
      ;;
    *)
      print_error "Invalid option."
      exit 1
      ;;
  esac
}

main
