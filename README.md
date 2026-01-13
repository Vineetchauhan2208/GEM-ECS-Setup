# Production ECS on EC2 Terraform Module

A production-grade ECS cluster on EC2 with zero-downtime deployments, secure secrets management, and cost-optimized mixed instance capacity.

## Features

- ✅ Zero-downtime deployments with ECS rolling updates
- ✅ Secure secrets from SSM Parameter Store (no secrets in Terraform)
- ✅ Mixed instances: On-Demand baseline + Spot overflow
- ✅ Multi-AZ deployment for high availability
- ✅ ECS Capacity Provider with managed scaling
- ✅ Private ECS instances (no public IPs)
- ✅ ALB integration with proper health checks
- ✅ Least-privilege IAM roles
- ✅ Container Insights enabled

## Prerequisites

1. Existing VPC with:
   - Public subnets for ALB
   - Private subnets for ECS instances
   - NAT Gateway or VPC endpoints for outbound connectivity

2. SSM Parameter Store parameters containing secrets

3. AWS credentials with sufficient permissions

## Usage

```hcl
module "ecs_service" {
  source = "./terraform"

  aws_region          = "us-east-1"
  vpc_id              = "vpc-abc123"
  private_subnet_ids  = ["subnet-123", "subnet-456"]
  public_subnet_ids   = ["subnet-789", "subnet-012"]
  
  service_name        = "my-app"
  container_image     = "myregistry/my-app:latest"
  container_port      = 8080
  
  ssm_parameter_names = [
    "/prod/my-app/database-url",
    "/prod/my-app/api-key"
  ]
  
  desired_count       = 3
  min_capacity        = 2
  max_capacity        = 10
}
