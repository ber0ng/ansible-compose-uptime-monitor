# auto stop at night
resource "aws_iam_role" "scheduler_iam_role" {
  name = "${var.project}-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "scheduler_stop" {
  name = "stop-instance"
  role = aws_iam_role.scheduler_iam_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "ec2:StopInstances"
      Resource = aws_instance.app_instance.arn
    }]
  })
}

resource "aws_scheduler_schedule" "nightly_stop" {
  name                         = "${var.project}-nightly-stop"
  schedule_expression          = var.shutdown_cron
  schedule_expression_timezone = "Asia/Manila"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.scheduler_iam_role.arn
    input    = jsonencode({ InstanceIds = [aws_instance.app_instance.id] })
  }
}
