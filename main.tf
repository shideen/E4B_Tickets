variable "aws_region" { 
  type    = string
  default = "eu-west-2" # London
}

provider "aws" {
  region = var.aws_region # Forces EVERYTHING without an alias Main provider (London)
}

# Add this second provider block for global edge resources (Cloudfront)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1" # Kept strictly for the Global WAF
}

data "aws_caller_identity" "current" {}

# ==========================================
# 1. Edge Security: AWS WAF v2 (CloudFront Scope)
# ==========================================
resource "aws_wafv2_web_acl" "global_waf" {
  provider     = aws.us_east_1 # Forces this resource into N. Virginia
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
    domain_name = replace(aws_api_gateway_stage.api_stage.invoke_url, "/^https?://([^/]+).*/", "$1")
    origin_id   = "APIGatewayOrigin"

    # FIX: Tell CloudFront to forward traffic straight into your API Stage context
    origin_path = "/${aws_api_gateway_stage.api_stage.stage_name}"

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

    # FIX 1: Explicitly tell CloudFront NEVER to cache API traffic
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled

    # FIX 2: Overrides the incoming Host header to match API Gateway
    origin_request_policy_id = aws_cloudfront_origin_request_policy.api_gateway_policy.id

    viewer_protocol_policy = "redirect-to-https"       
    
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
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "apigateway.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "apigw_sqs_policy" {
  name = "apigw_sqs_policy"
  role = aws_iam_role.apigw_sqs_role.id
  policy = jsonencode({
    Version   = "2012-10-17"
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
  credentials             = aws_iam_role.apigw_sqs_role.arn

  # FIX: Explicitly target the queue path directly via your AWS attributes
  uri = "arn:aws:apigateway:${var.aws_region}:sqs:path/${data.aws_caller_identity.current.account_id}/${aws_sqs_queue.ticket_queue.name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    # Keep MessageGroupId at the very front of the arguments string
    "application/json" = "Action=SendMessage&MessageGroupId=ticket_orders_group&MessageBody=$util.urlEncode($input.body)&MessageAttribute.1.Name=QueueType&MessageAttribute.1.Value.DataType=String&MessageAttribute.1.Value.StringValue=OrderPlacement"
  }

  # FIX: Forces Terraform to finish building the resource layout first
  depends_on = [
    aws_api_gateway_rest_api.ticket_api,
    aws_api_gateway_resource.order_resource,
    aws_api_gateway_method.post_order
  ]
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

# 1. The Deployment (Compiles the API routing snapshot)
resource "aws_api_gateway_deployment" "api_dep" {
  rest_api_id = aws_api_gateway_rest_api.ticket_api.id

  # Forces Terraform to redeploy the API if any endpoints or integrations change
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.order_resource.id,
      aws_api_gateway_method.post_order.id,
      aws_api_gateway_integration.api_to_sqs.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 2. The Stage (Exposes the deployment to the "prod" environment)
resource "aws_api_gateway_stage" "api_stage" {
  deployment_id = aws_api_gateway_deployment.api_dep.id
  rest_api_id   = aws_api_gateway_rest_api.ticket_api.id
  stage_name    = "prod"
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
  name         = "GlobalTicketOrders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "OrderId"
  attribute {
    name = "OrderId"
    type = "S"
  }
  stream_enabled   = true
  stream_view_type = "NEW_IMAGE"
}
# ==============================================================
# Automatically packages a dummy text file into a deployment zip
# ==============================================================
data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/dummy_payload.zip"
  
  source {
    content  = "exports.handler = async () => { return 'placeholder'; };"
    filename = "index.js"
  }
}

# ==========================================
# 5. LAMBDA 1: Ingestion Processor (SQS -> DynamoDB)
# ==========================================
resource "aws_lambda_function" "ingest_processor" {
  filename      = data.archive_file.lambda_placeholder.output_path
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
  filename      = data.archive_file.lambda_placeholder.output_path
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

resource "aws_iam_role" "lambda_execution_role" {
  name = "global_lambdas_execution_role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
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
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "events:PutEvents", Resource = aws_cloudwatch_event_bus.custom_bus.arn }]
  })
}

# Outputs the public CloudFront URL for testing the API entry point
output "cloudfront_url" {
  value       = "https://${aws_cloudfront_distribution.api_cdn.domain_name}"
  description = "The public CloudFront URL to send your mock ticket requests to."
}

# Outputs the underlying API Gateway Stage URL for direct troubleshooting
output "api_gateway_stage_url" {
  value       = aws_api_gateway_stage.api_stage.invoke_url
  description = "The direct internal regional URL for the API Gateway stage."
}

# Create a custom policy that forwards everything EXCEPT the Host header
resource "aws_cloudfront_origin_request_policy" "api_gateway_policy" {
  name    = "api-gateway-origin-policy"
  comment = "Custom policy to forward headers, cookies, and query strings while dropping the incoming Host header"

  cookies_config {
    cookie_behavior = "all"
  }

  query_strings_config {
    query_string_behavior = "all"
  }

  headers_config {
    header_behavior = "whitelist"
    
    # FIX: Changed from whitelist_headers to headers
    headers {
      items = [
        "Accept", 
        "Accept-Charset", 
        "Accept-Language", 
        "Authorization", 
        "Content-Type", 
        "Origin", 
        "Referer"
      ]
    }
  }  
}