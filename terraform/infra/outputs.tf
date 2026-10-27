output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "task_security_group_id" {
  value = aws_security_group.tasks.id
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "task_definition_family" {
  value = aws_ecs_task_definition.app.family
}

output "ecs_execution_role_arn" {
  value = aws_iam_role.ecs_execution.arn
}

variable "desired_count" {
  description = "Number of tasks to run"
  type        = number
  default     = 2
}

variable "health_check_path" {
  description = "Path the ALB uses to check task health"
  type        = string
  default     = "/health"
}

output "app_url" {
  description = "Open this in your browser"
  value       = "http://${aws_lb.main.dns_name}"
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}