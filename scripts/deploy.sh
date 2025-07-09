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

# Configuration
AWS_REGION=${AWS_REGION:-us-east-1}
CLUSTER_NAME=${CLUSTER_NAME:-counter-api-cluster}
ECR_REPOSITORY=${ECR_REPOSITORY:-counter-api}
IMAGE_TAG=${IMAGE_TAG:-latest}

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

# Function to install ingress-nginx
install_ingress_nginx() {
    print_status "Installing NGINX Ingress Controller..."
    
    if kubectl get namespace ingress-nginx > /dev/null 2>&1; then
        print_warning "Ingress NGINX namespace already exists"
    else
        kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/aws/deploy.yaml
        print_status "NGINX Ingress Controller installed"
    fi
    
    # Wait for ingress controller to be ready
    print_status "Waiting for NGINX Ingress Controller to be ready..."
    kubectl wait --namespace ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s || print_warning "Ingress controller might not be ready yet"
}

# Function to build and push Docker image
build_and_push_image() {
    print_status "Building and pushing Docker image..."
    
    # Login to ECR
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URI
    
    # Build image
    docker build --platform=linux/amd64 -t $ECR_REPOSITORY:$IMAGE_TAG .
    docker tag $ECR_REPOSITORY:$IMAGE_TAG $ECR_URI:$IMAGE_TAG
    
    # Push image
    docker push $ECR_URI:$IMAGE_TAG
    
    print_status "Docker image pushed successfully: $ECR_URI:$IMAGE_TAG"
}

# Function to deploy counter API
deploy_counter_api() {
    print_status "Deploying Counter API..."
    
    # Update deployment with ECR image
    sed -i.bak "s|image: counter-api:latest|image: $ECR_URI:$IMAGE_TAG|g" k8s/app-deployment.yaml
    
    # Apply Kubernetes manifests
    kubectl apply -f k8s/namespace.yaml
    kubectl apply -f k8s/redis-deployment.yaml
    kubectl apply -f k8s/redis-service.yaml
    kubectl apply -f k8s/app-deployment.yaml
    kubectl apply -f k8s/app-service.yaml
    
    # Wait for deployments to be ready
    print_status "Waiting for deployments to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/redis -n counter-api
    kubectl wait --for=condition=available --timeout=300s deployment/counter-api -n counter-api
    
    # Restore original deployment file
    mv k8s/app-deployment.yaml.bak k8s/app-deployment.yaml
    
    print_status "Counter API deployed successfully!"
}

# Function to test the deployment
test_deployment() {
    print_status "Testing deployment..."
    
    # Port forward for testing
    kubectl port-forward -n counter-api service/counter-api-service 8080:80 &
    PF_PID=$!
    sleep 10
    
    # Test health endpoint
    echo -e "\n${GREEN}Testing health endpoint:${NC}"
    curl -s http://localhost:8080/health | python -m json.tool 2>/dev/null || curl -s http://localhost:8080/health
    
    # Test read endpoint
    echo -e "\n${GREEN}Testing read endpoint:${NC}"
    curl -s http://localhost:8080/read | python -m json.tool 2>/dev/null || curl -s http://localhost:8080/read
    
    # Test write endpoint
    echo -e "\n${GREEN}Testing write endpoint:${NC}"
    curl -s -X POST http://localhost:8080/write | python -m json.tool 2>/dev/null || curl -s -X POST http://localhost:8080/write
    
    # Test read again
    echo -e "\n${GREEN}Testing read endpoint again:${NC}"
    curl -s http://localhost:8080/read | python -m json.tool 2>/dev/null || curl -s http://localhost:8080/read
    
    # Clean up port forward
    kill $PF_PID 2>/dev/null || true
    
    print_status "Tests completed successfully!"
}

# Function to show deployment status
show_status() {
    print_status "Deployment Status:"
    
    echo -e "\n${GREEN}Pods:${NC}"
    kubectl get pods -n counter-api
    
    echo -e "\n${GREEN}Services:${NC}"
    kubectl get services -n counter-api
    
    echo -e "\n${GREEN}Deployments:${NC}"
    kubectl get deployments -n counter-api
    
    print_status "To access the application:"
    print_status "kubectl port-forward -n counter-api service/counter-api-service 8080:80"
    print_status "Then visit: http://localhost:8080"
}

# Main execution
main() {
    local action=${1:-deploy}
    
    case $action in
        deploy)
            create_ecr_repository
            install_ingress_nginx
            build_and_push_image
            deploy_counter_api
            show_status
            ;;
        test)
            test_deployment
            ;;
        status)
            show_status
            ;;
        *)
            print_error "Unknown action: $action"
            echo "Usage: $0 [deploy|test|status]"
            exit 1
            ;;
    esac
}

# Run main function
main "$@" 