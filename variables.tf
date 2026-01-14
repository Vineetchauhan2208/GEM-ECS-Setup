variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (prod/staging/dev)"
  type        = string
  default     = "prod"
}

variable "vpc_id" {
  description = "Existing VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ECS instances"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for ALB"
  type        = list(string)
}

variable "service_name" {
  description = "ECS service name"
  type        = string
  default     = "app-service"
}

variable "container_image" {
  description = "Container image for the service"
  type        = string
  default     = "nginx:latest"
}

variable "container_port" {
  description = "Container port to expose"
  type        = number
  default     = 80
}

variable "desired_count" {
  description = "Desired number of tasks"
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Minimum number of tasks"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum number of tasks"
  type        = number
  default     = 10
}

variable "on_demand_base_capacity" {
  description = "Minimum number of On-Demand instances"
  type        = number
  default     = 1
}

variable "on_demand_percentage_above_base" {
  description = "Percentage of On-Demand instances above base"
  type        = number
  default     = 20
}

variable "ssm_parameter_names" {
  description = "List of SSM Parameter Store parameter names for secrets (ARNs or names)"
  type        = list(string)
  default     = []
}

variable "existing_security_group_ids" {
  description = "Existing security group IDs to attach to ECS instances"
  type        = list(string)
  default     = []
}

variable "health_check_path" {
  description = "Health check path for the target group"
  type        = string
  default     = "/health"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default = {
    Project     = "ECS-Assessment"
    Environment = "Production"
    ManagedBy   = "Terraform"
  }
}