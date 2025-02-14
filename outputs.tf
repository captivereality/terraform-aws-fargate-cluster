# ---------------------------------------------------------
# -- Module Outputs
# ---------------------------------------------------------

output "private_subnets" {
  description = "List of private subnets (on the ECS service hosting fargate)."
  value       = aws_subnet.fargate_ecs
}

output "public_subnets" {
  description = "List of public subnets (on the load balancer)."
  value       = aws_subnet.fargate_public
}

output "iam_role" {
  description = "IAM role for the fargate cluster. Can be used to link additional IAM permissions."
  value       = aws_iam_role.fargate_role
}

output "public_security_group_id" {
  description = "Id of the public security group (containing ALB)."
  value       = aws_security_group.alb.id
}

output "private_security_group_id" {
  description = "Id of the private security group (containing ECS Cluster)."
  value       = aws_security_group.fargate_ecs.id
}

output "cluster_arn" {
  description = "ECS Cluster ARN"
  value       = aws_ecs_cluster.fargate.arn
}

output "private_security_group" {
  description = "Private Security Group"
  value       = aws_security_group.fargate_ecs
}

output "task_definition" {
  description = "Task Defintion"
  value       = aws_ecs_task_definition.fargate
}

output "cluster_dns_name" {
  description = "The DNS Name of the Load Balancer"
  value       = aws_alb.fargate[0].dns_name
}