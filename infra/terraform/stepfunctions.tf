# Step Functions State Machine for AI Processing Pipeline
# Implements the complete workflow from video processing to summary generation

# Data sources for VPC and subnets
data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = length(var.private_subnet_ids) == 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Local values for VPC and subnet handling
locals {
  vpc_id     = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
  subnet_ids = length(var.private_subnet_ids) > 0 ? var.private_subnet_ids : data.aws_subnets.default[0].ids
}

resource "aws_sfn_state_machine" "ai_processing_pipeline" {
  name     = "ai-processing-pipeline"
  role_arn = aws_iam_role.step_functions_role.arn

  definition = jsonencode({
    Comment = "AI Processing Pipeline for Meeting Recordings"
    StartAt = "ValidateInput"
    TimeoutSeconds = 7200  # 2 hours max execution time
    Version = "1.0"

    States = {
      ValidateInput = {
        Type = "Task"
        Resource = aws_lambda_function.validate_input.arn
        TimeoutSeconds = 30
        Retry = [
          {
            ErrorEquals = ["Lambda.ServiceException", "Lambda.SdkClientException"]
            IntervalSeconds = 2
            MaxAttempts = 3
            BackoffRate = 2.0
          },
          {
            ErrorEquals = ["States.TaskFailed"]
            IntervalSeconds = 5
            MaxAttempts = 2
            BackoffRate = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["ValidationError"]
            Next = "ValidationFailed"
            ResultPath = "$.error"
          },
          {
            ErrorEquals = ["States.ALL"]
            Next = "ProcessingFailed"
            ResultPath = "$.error"
          }
        ]
        Next = "ProcessVideo"
      }

      ProcessVideo = {
        Type = "Task"
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          TaskDefinition = aws_ecs_task_definition.ffmpeg_processor.arn
          Cluster = aws_ecs_cluster.processing_cluster.arn
          LaunchType = "FARGATE"
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets = local.subnet_ids
              SecurityGroups = [aws_security_group.ffmpeg_sg.id]
              AssignPublicIp = "ENABLED"
            }
          }
          Overrides = {
            ContainerOverrides = [
              {
                Name = "ffmpeg-container"
                Environment = [
                  {
                    Name = "RECORDING_ID"
                    "Value.$" = "$.recording_id"
                  },
                  {
                    Name = "S3_BUCKET"
                    "Value.$" = "$.s3_bucket"
                  },
                  {
                    Name = "USER_ID"
                    "Value.$" = "$.user_id"
                  },
                  {
                    Name = "CHUNK_COUNT"
                    "Value.$" = "$.chunk_count"
                  },
                  {
                    Name = "AWS_REGION"
                    Value = var.aws_region
                  }
                ]
              }
            ]
          }
        }
        TimeoutSeconds = 1800  # 30 minutes for video processing
        Retry = [
          {
            ErrorEquals = ["ECS.TaskTimedOut", "ECS.TaskFailed"]
            IntervalSeconds = 60
            MaxAttempts = 2
            BackoffRate = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next = "ProcessingFailed"
            ResultPath = "$.error"
          }
        ]
        Next = "StartTranscription"
      }

      StartTranscription = {
        Type = "Task"
        Resource = aws_lambda_function.start_transcribe.arn
        TimeoutSeconds = 60
        Retry = [
          {
            ErrorEquals = ["Transcribe.LimitExceededException"]
            IntervalSeconds = 30
            MaxAttempts = 5
            BackoffRate = 2.0
          },
          {
            ErrorEquals = ["Lambda.ServiceException", "States.TaskFailed"]
            IntervalSeconds = 10
            MaxAttempts = 3
            BackoffRate = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next = "ProcessingFailed"
            ResultPath = "$.error"
          }
        ]
        Next = "WaitForTranscription"
      }

      WaitForTranscription = {
        Type = "Wait"
        Seconds = 30
        Next = "CheckTranscriptionStatus"
      }

      CheckTranscriptionStatus = {
        Type = "Task"
        Resource = aws_lambda_function.check_transcribe_status.arn
        TimeoutSeconds = 30
        Retry = [
          {
            ErrorEquals = ["Lambda.ServiceException", "States.TaskFailed"]
            IntervalSeconds = 5
            MaxAttempts = 3
            BackoffRate = 2.0
          }
        ]
        Next = "TranscriptionChoice"
      }

      TranscriptionChoice = {
        Type = "Choice"
        Choices = [
          {
            Variable = "$.transcription_status"
            StringEquals = "COMPLETED"
            Next = "GenerateSummary"
          },
          {
            Variable = "$.transcription_status"
            StringEquals = "IN_PROGRESS"
            Next = "WaitForTranscription"
          },
          {
            Variable = "$.transcription_status"
            StringEquals = "FAILED"
            Next = "ProcessingFailed"
          }
        ]
        Default = "ProcessingFailed"
      }

      GenerateSummary = {
        Type = "Task"
        Resource = aws_lambda_function.bedrock_summarize.arn
        TimeoutSeconds = 300  # 5 minutes for Bedrock processing
        Retry = [
          {
            ErrorEquals = ["Bedrock.ThrottlingException", "Bedrock.ModelNotReadyException"]
            IntervalSeconds = 30
            MaxAttempts = 5
            BackoffRate = 2.0
          },
          {
            ErrorEquals = ["Lambda.ServiceException", "States.TaskFailed"]
            IntervalSeconds = 15
            MaxAttempts = 3
            BackoffRate = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next = "ProcessingFailed"
            ResultPath = "$.error"
          }
        ]
        Next = "UpdateCatalog"
      }

      UpdateCatalog = {
        Type = "Task"
        Resource = aws_lambda_function.update_catalog.arn
        TimeoutSeconds = 60
        Retry = [
          {
            ErrorEquals = ["DynamoDB.ProvisionedThroughputExceededException"]
            IntervalSeconds = 10
            MaxAttempts = 5
            BackoffRate = 2.0
          },
          {
            ErrorEquals = ["Lambda.ServiceException", "States.TaskFailed"]
            IntervalSeconds = 5
            MaxAttempts = 3
            BackoffRate = 2.0
          }
        ]
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next = "ProcessingFailed"
            ResultPath = "$.error"
          }
        ]
        Next = "ProcessingCompleted"
      }

      ProcessingCompleted = {
        Type = "Succeed"
        Comment = "AI processing pipeline completed successfully"
      }

      ValidationFailed = {
        Type = "Fail"
        Cause = "Input validation failed"
        Error = "ValidationError"
      }

      ProcessingFailed = {
        Type = "Fail"
        Cause = "AI processing pipeline failed"
        Error = "ProcessingError"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions_logs.arn}:*"
    include_execution_data = true
    level                 = "ERROR"
  }

  tracing_configuration {
    enabled = true
  }

  tags = var.common_tags
}

# CloudWatch Log Group for Step Functions
resource "aws_cloudwatch_log_group" "step_functions_logs" {
  name              = "/aws/stepfunctions/ai-processing-pipeline"
  retention_in_days = 14

  tags = var.common_tags
}

# ECS Cluster for FFmpeg processing
resource "aws_ecs_cluster" "processing_cluster" {
  name = "ai-processing-cluster"

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"

      log_configuration {
        cloud_watch_encryption_enabled = false
        cloud_watch_log_group_name      = aws_cloudwatch_log_group.ecs_logs.name
      }
    }
  }

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.common_tags
}

# CloudWatch Log Group for ECS
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/ffmpeg-processor"
  retention_in_days = 7

  tags = var.common_tags
}

# ECR Repository for FFmpeg container
resource "aws_ecr_repository" "ffmpeg_processor" {
  name                 = "ffmpeg-processor"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.common_tags
}

# ECS Task Definition for FFmpeg processing
resource "aws_ecs_task_definition" "ffmpeg_processor" {
  family                   = "ffmpeg-processor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048  # 2 vCPU
  memory                   = 4096  # 4 GB

  execution_role_arn = aws_iam_role.ecs_execution_role.arn
  task_role_arn      = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name      = "ffmpeg-container"
      image     = "${aws_ecr_repository.ffmpeg_processor.repository_url}:latest"
      essential = true

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_logs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ffmpeg"
        }
      }

      # Environment variables will be overridden by Step Functions
      environment = [
        {
          name  = "AWS_DEFAULT_REGION"
          value = var.aws_region
        }
      ]

      # Resource requirements for video processing
      cpu    = 2048
      memory = 4096

      # Enable performance logging
      dockerLabels = {
        "purpose" = "video-processing"
        "component" = "ffmpeg"
      }
    }
  ])

  tags = var.common_tags
}

# Security Group for ECS tasks
resource "aws_security_group" "ffmpeg_sg" {
  name_prefix = "ffmpeg-processor-"
  vpc_id      = local.vpc_id

  # Allow all outbound traffic for S3 and other AWS service access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "ffmpeg-processor-sg"
  })
}

# IAM Role for Step Functions execution
resource "aws_iam_role" "step_functions_role" {
  name = "step-functions-ai-processing-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "states.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# IAM Policy for Step Functions
resource "aws_iam_role_policy" "step_functions_policy" {
  name = "step-functions-ai-processing-policy"
  role = aws_iam_role.step_functions_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.validate_input.arn,
          aws_lambda_function.start_transcribe.arn,
          aws_lambda_function.check_transcribe_status.arn,
          aws_lambda_function.bedrock_summarize.arn,
          aws_lambda_function.update_catalog.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks"
        ]
        Resource = [
          aws_ecs_task_definition.ffmpeg_processor.arn,
          "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/ai-processing-cluster/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "iam:PassRole"
        ]
        Resource = [
          aws_iam_role.ecs_execution_role.arn,
          aws_iam_role.ecs_task_role.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs-ffmpeg-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# Attach AWS managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Additional policy for ECR access
resource "aws_iam_role_policy" "ecs_execution_ecr_policy" {
  name = "ecs-execution-ecr-policy"
  role = aws_iam_role.ecs_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM Role for ECS Task (runtime permissions)
resource "aws_iam_role" "ecs_task_role" {
  name = "ecs-ffmpeg-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = var.common_tags
}

# Policy for ECS task to access S3 and DynamoDB
resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "ecs-ffmpeg-task-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.recordings.arn,
          "${aws_s3_bucket.recordings.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
        ]
        Resource = aws_dynamodb_table.meetings.arn
      }
    ]
  })
}

# Data source for current AWS account
data "aws_caller_identity" "current" {}

# Outputs
output "state_machine_arn" {
  description = "ARN of the AI processing Step Functions state machine"
  value       = aws_sfn_state_machine.ai_processing_pipeline.arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster for processing"
  value       = aws_ecs_cluster.processing_cluster.name
}

output "ecr_repository_url" {
  description = "URL of the ECR repository for FFmpeg processor"
  value       = aws_ecr_repository.ffmpeg_processor.repository_url
}