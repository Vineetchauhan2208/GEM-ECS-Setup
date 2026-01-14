aws_region = "us-east-1"
vpc_id     = "vpc-your-vpc-id"
private_subnet_ids = ["subnet-123", "subnet-456"]
public_subnet_ids  = ["subnet-789", "subnet-012"]

service_name = "my-app-service"
ssm_parameter_names = [
  "/prod/app/database-password",
  "/prod/app/api-key"
]

desired_count = 3
min_capacity  = 2
max_capacity  = 10
