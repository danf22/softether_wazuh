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

  eval "$var_name='$value'"
}

# Validate password meets CloudFormation pattern requirements
# Must be 8-64 chars with at least one lowercase, one uppercase, one digit, and one of .*+?-
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

  eval "$var_name='$value'"
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
    aws cloudformation describe-stack-events \
      --stack-name "$stack_name" \
      --region "$REGION" \
      --query "StackEvents[?ResourceStatus=='CREATE_FAILED'].[LogicalResourceId,ResourceStatusReason]" \
      --output table
    exit 1
  fi
}

# Deploy VPC stack
deploy_vpc() {
  print_info "=== Step 1: Deploying VPC ==="

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

# Deploy SoftEther internal (with Wazuh)
deploy_internal() {
  local stack_name="softether-internal"
  print_info "=== Deploying SoftEther + Wazuh (Internal with EIP) ==="

  prompt HUB_NAME "VPN Hub name" "VPN"
  prompt_password SOFTETHER_PASSWORD "SoftEther password"
  prompt_password WAZUH_PASSWORD "Wazuh admin password"
  prompt IPSEC_PSK "IPsec pre-shared key" "" true
  prompt DEFAULT_VPN_USER "Default VPN username"
  prompt_password DEFAULT_VPN_USER_PASSWORD "Default VPN user password"
  prompt INSTANCE_TYPE "EC2 instance type" "t3a.medium"

  aws cloudformation create-stack \
    --stack-name "$stack_name" \
    --template-body "file://${SCRIPT_DIR}/Sofether_internal.yml" \
    --region "$REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Project,Value=SoftEther-Wazuh \
    --parameters \
      ParameterKey=NameBurtualHubVPN,ParameterValue="$HUB_NAME" \
      ParameterKey=SoftetherPassword,ParameterValue="$SOFTETHER_PASSWORD" \
      ParameterKey=WazuhPassword,ParameterValue="$WAZUH_PASSWORD" \
      ParameterKey=IPsecPreSharedKey,ParameterValue="$IPSEC_PSK" \
      ParameterKey=DefaultVPNUser,ParameterValue="$DEFAULT_VPN_USER" \
      ParameterKey=DefaultVPNUserPassword,ParameterValue="$DEFAULT_VPN_USER_PASSWORD" \
      ParameterKey=EC2InstanceType,ParameterValue="$INSTANCE_TYPE" \
      ParameterKey=SubnetIdPublicSoftether,ParameterValue="$PUBLIC_SUBNET_1" \
      ParameterKey=SubnetIdPrivateWazuh,ParameterValue="$PRIVATE_SUBNET_1" \
      ParameterKey=VPCId,ParameterValue="$VPC_ID"

  wait_for_stack "$stack_name" "create"
  print_outputs "$stack_name"
}

# Deploy SoftEther internal (no Wazuh)
deploy_internal_no_wazuh() {
  local stack_name="softether-internal-no-wazuh"
  print_info "=== Deploying SoftEther Only (Internal with EIP, No Wazuh) ==="

  prompt HUB_NAME "VPN Hub name" "VPN"
  prompt_password SOFTETHER_PASSWORD "SoftEther password"
  prompt IPSEC_PSK "IPsec pre-shared key" "" true
  prompt DEFAULT_VPN_USER "Default VPN username"
  prompt_password DEFAULT_VPN_USER_PASSWORD "Default VPN user password"
  prompt INSTANCE_TYPE "EC2 instance type" "t3a.medium"

  aws cloudformation create-stack \
    --stack-name "$stack_name" \
    --template-body "file://${SCRIPT_DIR}/Sofether_internal_no_wazuh.yml" \
    --region "$REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Project,Value=SoftEther-Wazuh \
    --parameters \
      ParameterKey=NameBurtualHubVPN,ParameterValue="$HUB_NAME" \
      ParameterKey=SoftetherPassword,ParameterValue="$SOFTETHER_PASSWORD" \
      ParameterKey=IPsecPreSharedKey,ParameterValue="$IPSEC_PSK" \
      ParameterKey=DefaultVPNUser,ParameterValue="$DEFAULT_VPN_USER" \
      ParameterKey=DefaultVPNUserPassword,ParameterValue="$DEFAULT_VPN_USER_PASSWORD" \
      ParameterKey=EC2InstanceType,ParameterValue="$INSTANCE_TYPE" \
      ParameterKey=SubnetIdPublicSoftether,ParameterValue="$PUBLIC_SUBNET_1" \
      ParameterKey=VPCId,ParameterValue="$VPC_ID"

  wait_for_stack "$stack_name" "create"
  print_outputs "$stack_name"
}

# Deploy SoftEther external (with NLB)
deploy_external() {
  local stack_name="softether-external"
  print_info "=== Deploying SoftEther + Wazuh (External with NLB + TLS) ==="

  prompt HUB_NAME "VPN Hub name" "VPN"
  prompt_password SOFTETHER_PASSWORD "SoftEther password"
  prompt_password WAZUH_PASSWORD "Wazuh admin password"
  prompt IPSEC_PSK "IPsec pre-shared key" "" true
  prompt DEFAULT_VPN_USER "Default VPN username"
  prompt_password DEFAULT_VPN_USER_PASSWORD "Default VPN user password"
  prompt CERTIFICATE_ARN "ACM Certificate ARN"
  prompt INSTANCE_TYPE "EC2 instance type" "t3a.medium"

  aws cloudformation create-stack \
    --stack-name "$stack_name" \
    --template-body "file://${SCRIPT_DIR}/Sofether_external.yml" \
    --region "$REGION" \
    --capabilities CAPABILITY_NAMED_IAM \
    --tags Key=Project,Value=SoftEther-Wazuh \
    --parameters \
      ParameterKey=NameBurtualHubVPN,ParameterValue="$HUB_NAME" \
      ParameterKey=SoftetherPassword,ParameterValue="$SOFTETHER_PASSWORD" \
      ParameterKey=WazuhPassword,ParameterValue="$WAZUH_PASSWORD" \
      ParameterKey=IPsecPreSharedKey,ParameterValue="$IPSEC_PSK" \
      ParameterKey=DefaultVPNUser,ParameterValue="$DEFAULT_VPN_USER" \
      ParameterKey=DefaultVPNUserPassword,ParameterValue="$DEFAULT_VPN_USER_PASSWORD" \
      ParameterKey=CertificateArn,ParameterValue="$CERTIFICATE_ARN" \
      ParameterKey=EC2InstanceType,ParameterValue="$INSTANCE_TYPE" \
      ParameterKey=SubnetIdPrivateSoftether,ParameterValue="$PRIVATE_SUBNET_1" \
      ParameterKey=SubnetIdPrivateWazuh,ParameterValue="$PRIVATE_SUBNET_2" \
      ParameterKey=SubnetIdPublicOne,ParameterValue="$PUBLIC_SUBNET_1" \
      ParameterKey=SubnetIdPublicTwo,ParameterValue="$PUBLIC_SUBNET_2" \
      ParameterKey=VPCId,ParameterValue="$VPC_ID"

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
  echo "  - softether-internal-no-wazuh"
  echo "  - softether-external"
  echo "  - softether-vpc"
  echo ""
  read -p "Are you sure? (yes/no): " confirm
  if [ "$confirm" != "yes" ]; then
    print_info "Aborted."
    exit 0
  fi

  for stack in softether-internal softether-internal-no-wazuh softether-external; do
    if aws cloudformation describe-stacks --stack-name "$stack" --region "$REGION" &> /dev/null; then
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
  echo "==========================================="
  echo "  SoftEther VPN + Wazuh Deployment Tool"
  echo "==========================================="
  echo ""
  echo "Select deployment option:"
  echo ""
  echo "  1) SoftEther + Wazuh (Internal - Elastic IP)"
  echo "  2) SoftEther Only (Internal - No Wazuh)"
  echo "  3) SoftEther + Wazuh (External - NLB + TLS)"
  echo "  4) Destroy all stacks"
  echo "  5) Exit"
  echo ""
  read -p "Option [1-5]: " choice

  if [ "$choice" != "5" ]; then
    prompt REGION "AWS Region" "us-east-1"
  fi

  check_prerequisites

  case "$choice" in
    1)
      deploy_vpc
      deploy_internal
      ;;
    2)
      deploy_vpc
      deploy_internal_no_wazuh
      ;;
    3)
      deploy_vpc
      deploy_external
      ;;
    4)
      destroy
      ;;
    5)
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
