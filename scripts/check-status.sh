#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_status "Checking AWS EKS Cluster Status"
print_status "==============================="

# Check cluster info
echo -e "\n${GREEN}Cluster Information:${NC}"
kubectl cluster-info

# Check nodes
echo -e "\n${GREEN}Nodes:${NC}"
kubectl get nodes

# Check namespaces
echo -e "\n${GREEN}Namespaces:${NC}"
kubectl get namespaces

# Check system pods
echo -e "\n${GREEN}System Pods:${NC}"
kubectl get pods -n kube-system

# Check cert-manager
echo -e "\n${GREEN}Cert-Manager:${NC}"
kubectl get pods -n cert-manager

# Check ingress-nginx
echo -e "\n${GREEN}Ingress NGINX:${NC}"
kubectl get pods -n ingress-nginx

# Check if counter-api namespace exists
echo -e "\n${GREEN}Counter API Namespace:${NC}"
kubectl get namespace counter-api 2>/dev/null || echo "counter-api namespace not found"

# Check if counter-api is deployed
echo -e "\n${GREEN}Counter API Deployment:${NC}"
kubectl get all -n counter-api 2>/dev/null || echo "counter-api not deployed"

# Check AWS Load Balancer Controller
echo -e "\n${GREEN}AWS Load Balancer Controller:${NC}"
kubectl get deployment aws-load-balancer-controller -n kube-system 2>/dev/null || echo "AWS Load Balancer Controller not found"

# Check metrics server
echo -e "\n${GREEN}Metrics Server:${NC}"
kubectl get deployment metrics-server -n kube-system 2>/dev/null || echo "Metrics Server not found"

# Check ECR repository
echo -e "\n${GREEN}ECR Repository:${NC}"
aws ecr describe-repositories --repository-names counter-api --region us-east-1 2>/dev/null || echo "ECR repository not found"

print_status "Status check completed!"
print_status "If you see all components are running, you can deploy the counter API with: ./scripts/deploy.sh deploy"
print_status "If you encounter issues, you can run: ./scripts/setup-aws.sh fix" 