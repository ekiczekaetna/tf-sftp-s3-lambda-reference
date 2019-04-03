// This Terraform configuration file provides a reference implementation for an
// SFTP service, an S3 bucket for the files that are transferred to the SFTP
// service, and a Lambda to run when a new file is placed in the S3 bucket.


provider "aws" {
  region = "us-east-1"
}

// AWS Simple Storage Service Bucket
resource "aws_s3_bucket" "s3-bucket" {
  bucket = "reference-implementation-s3-bucket"
  acl    = "private"
  force_destroy = "true"

  versioning {
    enabled = true
  }

  tags = {
    Name        = "Reference implementation S3 bucket"
    Environment = "Dev"
  }
}

// AWS Transfer Service Server
resource "aws_iam_role" "transfer-server-iam-role" {
    name = "reference-implementation-transfer-server-iam-role"

    assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
        "Effect": "Allow",
        "Principal": {
            "Service": "transfer.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy" "transfer-server-iam-policy" {
    name = "reference-implementation-transfer-server-iam-policy"
    role = "${aws_iam_role.transfer-server-iam-role.id}"
    policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
        "Sid": "AllowFullAccesstoCloudWatchLogs",
        "Effect": "Allow",
        "Action": [
            "logs:*"
        ],
        "Resource": "*"
        }
    ]
}
POLICY
}

// NOTE: Currently there is no way to specify private VPC endpoint.
// See https://github.com/terraform-providers/terraform-provider-aws/pull/7977#issuecomment-479046938
resource "aws_transfer_server" "transfer-server" {
  identity_provider_type = "SERVICE_MANAGED"
  logging_role = "${aws_iam_role.transfer-server-iam-role.arn}"

  tags = {
    Name   = "Reference implementation Transfer Service"
    Environment    = "Dev"
  }
}

// AWS Transfer Service User
resource "aws_iam_role" "transfer-user-iam-role" {
    name = "reference-implementation-transfer-user-iam-role"

    assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
        "Effect": "Allow",
        "Principal": {
            "Service": "transfer.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy" "transfer-user-iam-policy" {
    name = "reference-implementation-transfer-user-iam-policy"
    role = "${aws_iam_role.transfer-user-iam-role.id}"
    policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowFullAccesstoS3",
            "Effect": "Allow",
            "Action": [
                "s3:*"
            ],
            "Resource": "*"
        }
    ]
}
POLICY
}

resource "aws_transfer_user" "transfer-user" {
    server_id      = "${aws_transfer_server.transfer-server.id}"
    user_name      = "ritransferuser"
    home_directory = "/${aws_s3_bucket.s3-bucket.id}"
    role           = "${aws_iam_role.transfer-user-iam-role.arn}"
}

// AWS Lambda
resource "aws_iam_role" "lambda-execution-role" {
  name = "reference-implementation-lambda-execution-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.lambda-function.arn}"
  principal     = "s3.amazonaws.com"
  source_arn    = "${aws_s3_bucket.s3-bucket.arn}"
}

resource "aws_lambda_function" "lambda-function" {
    function_name = "reference-implementation-lambda-function"
    handler = "index.handler"
    runtime = "nodejs8.10"
    filename = "function.zip"
    source_code_hash = "${base64sha256(file("function.zip"))}"
    role = "${aws_iam_role.lambda-execution-role.arn}"
}

// AWS S3 bucket notification to Lambda
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = "${aws_s3_bucket.s3-bucket.id}"

  lambda_function {
    lambda_function_arn = "${aws_lambda_function.lambda-function.arn}"
    events              = ["s3:ObjectCreated:*"]
  }
}

// AWS Lambda logging
resource "aws_cloudwatch_log_group" "cloudwatch-log-group" {
  name              = "/aws/lambda/${aws_lambda_function.lambda-function.function_name}"
  retention_in_days = 14
}

# See also the following AWS managed policy: AWSLambdaBasicExecutionRole
resource "aws_iam_policy" "lambda-logging" {
  name = "reference-implementation-lambda-logging"
  path = "/"
  description = "IAM policy for logging from a lambda"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams"
      ],
      "Resource": "arn:aws:logs:*:*:*",
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "lambda-logs" {
  role = "${aws_iam_role.lambda-execution-role.name}"
  policy_arn = "${aws_iam_policy.lambda-logging.arn}"
}
