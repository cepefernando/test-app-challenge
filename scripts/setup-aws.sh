#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-counter-api-cluster}
ECR_REPOSITORY=${ECR_REPOSITORY:-counter-api}
NODE_TYPE=${NODE_TYPE:-t3.medium}
MIN_NODES=${MIN_NODES:-1}
MAX_NODES=${MAX_NODES:-4}
DESIRED_NODES=${DESIRED_NODES:-2}

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to ensure Helm is installed
ensure_helm() {
    if ! command_exists helm; then
        print_status "Installing Helm..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    if ! command_exists aws; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! command_exists eksctl; then
        print_error "eksctl is not installed. Please install it first."
        exit 1
    fi
    
    if ! command_exists kubectl; then
        print_error "kubectl is not installed. Please install it first."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
        print_error "AWS credentials not configured. Please run 'aws configure' first."
        exit 1
    fi
    
    print_status "Prerequisites check passed!"
}

# Function to create ECR repository
create_ecr_repository() {
    print_status "Creating ECR repository..."
    
    if aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION > /dev/null 2>&1; then
        print_warning "ECR repository '$ECR_REPOSITORY' already exists."
    else
        aws ecr create-repository --repository-name $ECR_REPOSITORY --region $AWS_REGION
        print_status "ECR repository '$ECR_REPOSITORY' created successfully."
    fi
    
    # Get repository URI
    ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION --query 'repositories[0].repositoryUri' --output text)
    print_status "ECR repository URI: $ECR_URI"
}

# Function to create EKS cluster
create_eks_cluster() {
    print_status "Creating EKS cluster..."
    
    if eksctl get cluster --name $CLUSTER_NAME --region $AWS_REGION > /dev/null 2>&1; then
        print_warning "EKS cluster '$CLUSTER_NAME' already exists."
    else
        print_status "Creating EKS cluster '$CLUSTER_NAME'... This may take 10-15 minutes."
        
        eksctl create cluster \
            --name $CLUSTER_NAME \
            --region $AWS_REGION \
            --nodegroup-name standard-workers \
            --node-type $NODE_TYPE \
            --nodes $DESIRED_NODES \
            --nodes-min $MIN_NODES \
            --nodes-max $MAX_NODES \
            --managed
        
        print_status "EKS cluster '$CLUSTER_NAME' created successfully."
    fi
    
    # Update kubeconfig
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
    print_status "kubectl configured for cluster '$CLUSTER_NAME'."
}

# Function to install essential addons (improved version)
install_addons() {
    print_status "Installing essential addons..."
    
    # Ensure Helm is installed
    ensure_helm
    
    # Install cert-manager first
    print_status "Installing cert-manager..."
    kubectl apply \
        --validate=false \
        -f https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml
    
    # Wait for cert-manager to be ready
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager -n cert-manager --timeout=300s
    
    # Install AWS Load Balancer Controller
    print_status "Installing AWS Load Balancer Controller..."
    
    # Create IAM policy
    curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.4.7/docs/install/iam_policy.json
    
    aws iam create-policy \
        --policy-name AWSLoadBalancerControllerIAMPolicy \
        --policy-document file://iam_policy.json \
        --no-cli-pager || print_warning "Policy might already exist"
    
    rm -f iam_policy.json
    
    # Associate IAM OIDC provider
    print_status "Associating IAM OIDC provider..."
    eksctl utils associate-iam-oidc-provider \
        --region=$AWS_REGION \
        --cluster=$CLUSTER_NAME \
        --approve || print_warning "OIDC provider might already exist"
    
    # Create service account
    eksctl create iamserviceaccount \
        --cluster=$CLUSTER_NAME \
        --namespace=kube-system \
        --name=aws-load-balancer-controller \
        --role-name AmazonEKSLoadBalancerControllerRole \
        --attach-policy-arn=arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy \
        --approve || print_warning "Service account might already exist"
    
    # Install using Helm (more reliable than raw YAML)
    print_status "Installing AWS Load Balancer Controller using Helm..."
    
    # Add the EKS chart repo
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update
    
    # Get VPC ID
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/VPC" --query 'Vpcs[0].VpcId' --output text)
    
    # Install the controller
    helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        -n kube-system \
        --set clusterName=$CLUSTER_NAME \
        --set serviceAccount.create=false \
        --set serviceAccount.name=aws-load-balancer-controller \
        --set region=$AWS_REGION \
        --set vpcId=$VPC_ID \
        --wait || print_warning "Controller might already be installed"
    
    # Install metrics server
    print_status "Installing metrics server..."
    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    
    # Install ingress-nginx
    print_status "Installing NGINX ingress controller..."
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/aws/deploy.yaml
    
    # Wait for components to be ready
    print_status "Waiting for components to be ready..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=metrics-server -n kube-system --timeout=300s || print_warning "Metrics server might take longer to be ready"
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=ingress-nginx -n ingress-nginx --timeout=300s || print_warning "Ingress controller might take longer to be ready"
    
    print_status "Addons installed successfully!"
}

# Function to fix existing installation issues
fix_installation() {
    print_status "Fixing existing installation issues..."
    
    # Ensure Helm is installed
    ensure_helm
    
    # Clean up any existing failed installation
    kubectl delete deployment aws-load-balancer-controller -n kube-system 2>/dev/null || true
    kubectl delete service aws-load-balancer-controller-webhook-service -n kube-system 2>/dev/null || true
    
    # Re-run the addons installation
    install_addons
    
    print_status "Installation fixes completed!"
}

# Function to create GitHub secrets
create_github_secrets() {
    print_status "GitHub Secrets Configuration"
    
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    print_status "Add these secrets to your GitHub repository:"
    echo -e "${YELLOW}AWS_ACCESS_KEY_ID${NC}: Your AWS access key ID"
    echo -e "${YELLOW}AWS_SECRET_ACCESS_KEY${NC}: Your AWS secret access key"
    echo -e "${YELLOW}SLACK_WEBHOOK_URL${NC}: (Optional) Your Slack webhook URL for notifications"
    
    print_status "Update these values in .github/workflows/deploy.yml:"
    echo -e "${YELLOW}AWS_REGION${NC}: $AWS_REGION"
    echo -e "${YELLOW}ECR_REPOSITORY${NC}: $ECR_REPOSITORY"
    echo -e "${YELLOW}EKS_CLUSTER_NAME${NC}: $CLUSTER_NAME"
    echo -e "${YELLOW}ECR_URI${NC}: $ECR_URI"
}

# Function to verify setup
verify_setup() {
    print_status "Verifying setup..."
    
    # Check cluster
    kubectl cluster-info
    
    # Check nodes
    kubectl get nodes
    
    # Check critical system pods
    kubectl get pods -n kube-system | grep -E "(aws-load-balancer-controller|metrics-server)" || print_warning "Some system pods might not be ready yet"
    kubectl get pods -n ingress-nginx || print_warning "Ingress controller might not be ready yet"
    kubectl get pods -n cert-manager || print_warning "Cert-manager might not be ready yet"
    
    print_status "Setup verification completed!"
}

# Function to show help
show_help() {
    echo "Usage: $0 [OPTION]"
    echo "Setup AWS infrastructure for Counter API"
    echo ""
    echo "Options:"
    echo "  setup     Create ECR repository and EKS cluster (default)"
    echo "  ecr       Create ECR repository only"
    echo "  cluster   Create EKS cluster only"
    echo "  addons    Install essential addons"
    echo "  fix       Fix existing installation issues"
    echo "  verify    Verify the setup"
    echo "  cleanup   Delete all resources"
    echo "  help      Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  AWS_REGION        AWS region (default: us-east-1)"
    echo "  CLUSTER_NAME      EKS cluster name (default: counter-api-cluster)"
    echo "  ECR_REPOSITORY    ECR repository name (default: counter-api)"
    echo "  NODE_TYPE         EC2 instance type (default: t3.medium)"
    echo "  MIN_NODES         Minimum number of nodes (default: 1)"
    echo "  MAX_NODES         Maximum number of nodes (default: 4)"
    echo "  DESIRED_NODES     Desired number of nodes (default: 2)"
    echo ""
    echo "Examples:"
    echo "  $0 setup"
    echo "  AWS_REGION=us-west-2 $0 setup"
    echo "  $0 fix"
    echo "  $0 cleanup"
}

# Function to cleanup resources
cleanup() {
    print_status "Cleaning up resources..."
    
    read -p "Are you sure you want to delete all resources? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Cleanup cancelled."
        return
    fi
    
    # Delete EKS cluster
    if eksctl get cluster --name $CLUSTER_NAME --region $AWS_REGION > /dev/null 2>&1; then
        print_status "Deleting EKS cluster..."
        eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION
    fi
    
    # Delete ECR repository
    if aws ecr describe-repositories --repository-names $ECR_REPOSITORY --region $AWS_REGION > /dev/null 2>&1; then
        print_status "Deleting ECR repository..."
        aws ecr delete-repository --repository-name $ECR_REPOSITORY --region $AWS_REGION --force
    fi
    
    # Delete IAM policy
    aws iam delete-policy --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/AWSLoadBalancerControllerIAMPolicy || true
    
    print_status "Cleanup completed!"
}

# Main execution
main() {
    local action=${1:-setup}
    
    case $action in
        setup)
            check_prerequisites
            create_ecr_repository
            create_eks_cluster
            install_addons
            create_github_secrets
            verify_setup
            ;;
        ecr)
            check_prerequisites
            create_ecr_repository
            ;;
        cluster)
            check_prerequisites
            create_eks_cluster
            ;;
        addons)
            check_prerequisites
            install_addons
            ;;
        fix)
            check_prerequisites
            fix_installation
            verify_setup
            ;;
        verify)
            check_prerequisites
            verify_setup
            ;;
        cleanup)
            check_prerequisites
            cleanup
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown action: $action"
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@" 