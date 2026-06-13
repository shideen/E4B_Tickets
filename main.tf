# ==========================================
# 1. Edge Security: AWS WAF v2 (CloudFront Scope)
# ==========================================
resource "aws_wafv2_web_acl" "global_waf" {
  name        = "global-ticketing-bot-protection"
  description = "Edge WAF to drop malicious bot traffic and enforce rate limits"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # Rule: Enforce rate limit of 100 requests per 5 minutes per IP
  rule {
    name     = "IPRateLimit"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 100
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IPRateLimitMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "GlobalWAFMetric"
    sampled_requests_enabled   = true
  }
}

# ==========================================
# 2. Global Content Delivery: Amazon CloudFront
# ==========================================
resource "aws_cloudfront_distribution" "api_cdn" {
  enabled = true

  # Attach our Edge WAF directly to CloudFront
  web_acl_id = aws_wafv2_web_acl.global_waf.arn

  origin {
    domain_name = replace(aws_api_gateway_deployment.api_dep.invoke_url, "/^https?://([^/]+).*/", "$1")
    origin_id   = "APIGatewayOrigin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "APIGatewayOrigin"
    viewer_protocol_policy = "redirect-to-https"

    forwarded_values {
      query_string = true
      headers      = ["Authorization", "Host"]
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# ==========================================
# 3. Public Entryway: API Gateway to SQS Direct Integration
# ==========================================
resource "aws_api_gateway_rest_api" "ticket_api" {
  name        = "TicketingIngestionAPI"
  description = "Public API endpoint mapped to CloudFront"
}

resource "aws_api_gateway_resource" "order_resource" {
  rest_api_id = aws_api_gateway_rest_api.ticket_api.id
  parent_id   = aws_api_gateway_rest_api.ticket_api.root_resource_id
  path_part   = "order"
}

# IAM Role so API Gateway can write directly to SQS without a Lambda
resource "aws_iam_role" "apigw_sqs_role" {
  name = "apigw_sqs_direct_role"
  assume_role_policy = jsonencode({
    Version = "2011-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "apigateway.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "apigw_sqs_policy" {
  name = "apigw_sqs_policy"
  role = aws_iam_role.apigw_sqs_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sqs:SendMessage", Resource = aws_sqs_queue.ticket_queue.arn }]
  })
}

resource "aws_api_gateway_method" "post_order" {
  rest_api_id   = aws_api_gateway_rest_api.ticket_api.id
  resource_id   = aws_api_gateway_resource.order_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

# The Integration: Maps the POST payload straight into SQS
resource "aws_api_gateway_integration" "api_to_sqs" {
  rest_api_id             = aws_api_gateway_rest_api.ticket_api.id
  resource_id             = aws_api_gateway_resource.order_resource.id
  http_method             = aws_api_gateway_method.post_order.http_method
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:aws:apigateway:${var.aws_region}:sqs:path/${aws_sqs_queue.ticket_queue.name}"
  credentials             = aws_iam_role.apigw_sqs_role.arn

  request_templates = {
    "application/json" = "Action=SendMessage&MessageBody=$input.body&MessageAttribute.1.Name=QueueType&MessageAttribute.1.Value.DataType=String&MessageAttribute.1.Value.StringValue=OrderPlacement"
  }
}

resource "aws_api_gateway_method_response" "response_200" {
  rest_api_id = aws_api_gateway_rest_api.ticket_api.id
  resource_id = aws_api_gateway_resource.order_resource.id
  http_method = aws_api_gateway_method.post_order.http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "api_to_sqs_response" {
  rest_api_id = aws_api_gateway_rest_api.ticket_api.id
  resource_id = aws_api_gateway_resource.order_resource.id
  http_method = aws_api_gateway_method.post_order.http_method
  status_code = aws_api_gateway_method_response.response_200.status_code
  depends_on  = [aws_api_gateway_integration.api_to_sqs]
}

resource "aws_api_gateway_deployment" "api_dep" {
  rest_api_id = aws_api_gateway_rest_api.ticket_api.id
  stage_name  = "prod"
  depends_on  = [aws_api_gateway_integration.api_to_sqs]
}

# ==========================================
# 4. Ingestion Buffer & Database
# ==========================================
resource "aws_sqs_queue" "ticket_queue" {
  name                        = "ticket-orders.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
}

resource "aws_dynamodb_table" "ticket_table" {
  name             = "GlobalTicketOrders"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "OrderId"
  attribute { name = "OrderId", type = "S" }
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"
}

# ==========================================
# 5. LAMBDA 1: Ingestion Processor (SQS -> DynamoDB)
# ==========================================
resource "aws_lambda_function" "ingest_processor" {
  filename      = "dummy_payload.zip"
  function_name = "CoreOrderIngestProcessor"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
}

resource "aws_lambda_event_source_mapping" "sqs_to_lambda1" {
  event_source_arn = aws_sqs_queue.ticket_queue.arn
  function_name    = aws_lambda_function.ingest_processor.arn
  batch_size       = 10
}

# ==========================================
# 6. Event Routing Hub: Amazon EventBridge
# ==========================================
resource "aws_cloudwatch_event_bus" "custom_bus" {
  name = "ticketing-domain-event-bus"
}

# ==========================================
# 7. LAMBDA 2: Event Router (DynamoDB Streams -> EventBridge)
# ==========================================
resource "aws_lambda_function" "stream_router" {
  filename      = "dummy_payload.zip"
  function_name = "DynamoDBStreamToEventBridgeRouter"
  role          = aws_iam_role.lambda_execution_role.arn
  handler       = "index.handler"
  runtime       = "nodejs18.x"
}

resource "aws_lambda_event_source_mapping" "ddb_stream_to_lambda2" {
  event_source_arn  = aws_dynamodb_table.ticket_table.stream_arn
  function_name     = aws_lambda_function.stream_router.arn
  starting_position = "LATEST"
}

# ==========================================
# 8. Shared IAM Framework & Basic Configurations
# ==========================================
variable "aws_region" { default = "eu-west-2" }

resource "aws_iam_role" "lambda_execution_role" {
  name = "global_lambdas_execution_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

# Add standard AWS-managed execution policies for simplicity in this file
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}
resource "aws_iam_role_policy_attachment" "lambda_ddb" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaDynamoDBExecutionRole"
}
resource "aws_iam_role_policy" "lambda_eventbridge" {
  name = "lambda_eventbridge_publish"
  role = aws_iam_role.lambda_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "events:PutEvents", Resource = aws_cloudwatch_event_bus.custom_bus.arn }]
  })
}