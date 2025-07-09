#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
IMAGE_NAME="counter-api"
IMAGE_TAG="latest"
NAMESPACE="counter-api"
DOCKER_REGISTRY=${DOCKER_REGISTRY:-""}

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

# Function to wait for deployment to be ready
wait_for_deployment() {
    local deployment_name=$1
    local namespace=$2
    local timeout=${3:-300}
    
    print_status "Waiting for deployment $deployment_name to be ready..."
    kubectl wait --for=condition=available --timeout=${timeout}s deployment/$deployment_name -n $namespace
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    if ! command_exists docker; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    
    if ! command_exists kubectl; then
        print_error "kubectl is not installed. Please install kubectl first."
        exit 1
    fi
    
    # Check if kubectl can connect to cluster
    if ! kubectl cluster-info > /dev/null 2>&1; then
        print_error "Cannot connect to Kubernetes cluster. Please check your kubectl configuration."
        exit 1
    fi
    
    print_status "Prerequisites check passed!"
}

# Function to build Docker image
build_image() {
    print_status "Building Docker image..."
    
    if [ -n "$DOCKER_REGISTRY" ]; then
        FULL_IMAGE_NAME="${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
    else
        FULL_IMAGE_NAME="${IMAGE_NAME}:${IMAGE_TAG}"
    fi
    
    docker build --platform=linux/amd64 -t $FULL_IMAGE_NAME .
    
    if [ $? -eq 0 ]; then
        print_status "Docker image built successfully: $FULL_IMAGE_NAME"
    else
        print_error "Failed to build Docker image"
        exit 1
    fi
    
    # Push image if registry is specified
    if [ -n "$DOCKER_REGISTRY" ]; then
        print_status "Pushing image to registry..."
        docker push $FULL_IMAGE_NAME
        if [ $? -eq 0 ]; then
            print_status "Image pushed successfully"
        else
            print_error "Failed to push image to registry"
            exit 1
        fi
    fi
}

# Function to deploy to Kubernetes
deploy_to_k8s() {
    print_status "Deploying to Kubernetes..."
    
    # Create namespace
    kubectl apply -f k8s/namespace.yaml
    
    # Deploy Redis
    print_status "Deploying Redis..."
    kubectl apply -f k8s/redis-deployment.yaml
    kubectl apply -f k8s/redis-service.yaml
    
    # Wait for Redis to be ready
    wait_for_deployment "redis" $NAMESPACE 180
    
    # Deploy application
    print_status "Deploying Counter API..."
    
    # Update image in deployment if using registry
    if [ -n "$DOCKER_REGISTRY" ]; then
        sed -i.bak "s|image: counter-api:latest|image: ${DOCKER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}|g" k8s/app-deployment.yaml
    fi
    
    kubectl apply -f k8s/app-deployment.yaml
    kubectl apply -f k8s/app-service.yaml
    
    # Wait for application to be ready
    wait_for_deployment "counter-api" $NAMESPACE 300
    
    # Deploy ingress
    print_status "Deploying Ingress..."
    kubectl apply -f k8s/ingress.yaml
    
    # Restore original deployment file if modified
    if [ -f k8s/app-deployment.yaml.bak ]; then
        mv k8s/app-deployment.yaml.bak k8s/app-deployment.yaml
    fi
    
    print_status "Deployment completed successfully!"
}

# Function to check deployment status
check_deployment_status() {
    print_status "Checking deployment status..."
    
    echo -e "\n${GREEN}Pods:${NC}"
    kubectl get pods -n $NAMESPACE
    
    echo -e "\n${GREEN}Services:${NC}"
    kubectl get services -n $NAMESPACE
    
    echo -e "\n${GREEN}Ingress:${NC}"
    kubectl get ingress -n $NAMESPACE
    
    echo -e "\n${GREEN}HPA:${NC}"
    kubectl get hpa -n $NAMESPACE
    
    # Get service endpoint
    print_status "Getting service endpoint..."
    SERVICE_IP=$(kubectl get service counter-api-loadbalancer -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [ -z "$SERVICE_IP" ]; then
        SERVICE_IP=$(kubectl get service counter-api-loadbalancer -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    fi
    
    if [ -n "$SERVICE_IP" ]; then
        echo -e "\n${GREEN}Service available at: http://$SERVICE_IP${NC}"
        echo -e "${GREEN}Test endpoints:${NC}"
        echo -e "  Health check: http://$SERVICE_IP/health"
        echo -e "  Read counter: http://$SERVICE_IP/read"
        echo -e "  Write counter: curl -X POST http://$SERVICE_IP/write"
    else
        print_warning "LoadBalancer IP not yet assigned. Use port-forward for testing:"
        echo -e "${YELLOW}kubectl port-forward -n $NAMESPACE service/counter-api-service 8080:80${NC}"
    fi
}

# Function to run tests
run_tests() {
    print_status "Running basic tests..."
    
    # Port forward for testing
    kubectl port-forward -n $NAMESPACE service/counter-api-service 8080:80 &
    PF_PID=$!
    sleep 5
    
    # Test health endpoint
    echo -e "\n${GREEN}Testing health endpoint:${NC}"
    curl -s http://localhost:8080/health | jq . 2>/dev/null || curl -s http://localhost:8080/health
    
    # Test read endpoint
    echo -e "\n${GREEN}Testing read endpoint:${NC}"
    curl -s http://localhost:8080/read | jq . 2>/dev/null || curl -s http://localhost:8080/read
    
    # Test write endpoint
    echo -e "\n${GREEN}Testing write endpoint:${NC}"
    curl -s -X POST http://localhost:8080/write | jq . 2>/dev/null || curl -s -X POST http://localhost:8080/write
    
    # Test read again
    echo -e "\n${GREEN}Testing read endpoint again:${NC}"
    curl -s http://localhost:8080/read | jq . 2>/dev/null || curl -s http://localhost:8080/read
    
    # Clean up port forward
    kill $PF_PID 2>/dev/null || true
    
    print_status "Tests completed!"
}

# Function to clean up deployment
cleanup() {
    print_status "Cleaning up deployment..."
    kubectl delete namespace $NAMESPACE --ignore-not-found=true
    print_status "Cleanup completed!"
}

# Function to show help
show_help() {
    echo "Usage: $0 [OPTION]"
    echo "Deploy Counter API to Kubernetes"
    echo ""
    echo "Options:"
    echo "  deploy    Build and deploy the application (default)"
    echo "  status    Check deployment status"
    echo "  test      Run basic tests against the deployed application"
    echo "  cleanup   Remove the deployment"
    echo "  help      Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  DOCKER_REGISTRY   Docker registry to push images to (optional)"
    echo ""
    echo "Examples:"
    echo "  $0 deploy"
    echo "  DOCKER_REGISTRY=myregistry.com $0 deploy"
    echo "  $0 status"
    echo "  $0 test"
    echo "  $0 cleanup"
}

# Main execution
main() {
    local action=${1:-deploy}
    
    case $action in
        deploy)
            check_prerequisites
            build_image
            deploy_to_k8s
            check_deployment_status
            ;;
        status)
            check_deployment_status
            ;;
        test)
            run_tests
            ;;
        cleanup)
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