# High-Frequency Global Ticketing Engine (Enterprise-Scale IaC)

This repository contains a production-ready, highly resilient Infrastructure-as-Code (Terraform) blueprint for a global, high-concurrency ticket ordering engine. It is architected specifically to handle instantaneous, massive traffic spikes (e.g., major ticket drops) while guaranteeing zero double-bookings, robust bot mitigation at the edge, and asynchronous downstream fulfillment.

## 🏛️ System Architecture Layout



The system is decoupled into three distinct architectural phases:

1. **The Edge & Inbound Defense Layer:** AWS WAF inspects traffic at global Edge Locations via Amazon CloudFront, dropping malicious bot vectors and enforcing strict IP rate-limiting before packets reach the regional infrastructure.
2. **The Compute-Bypass Ingestion Layer:** Amazon API Gateway bypasses the compute layer entirely, writing incoming POST payloads directly into an Amazon SQS FIFO Queue. This eliminates AWS Lambda concurrency limits as a point of ingestion failure.
3. **The Event-Driven Fulfillment Domain:** A two-stage Lambda pipeline isolates database ingestion from downstream event distribution. DynamoDB Streams capture committed records, triggering an Event Router to fan out standardized domain events via Amazon EventBridge.

---

## 🛠️ Deep-Dive: Key Architectural Decisions

### 1. Ingestion Compute-Bypass Pattern
* **The Implementation:** `aws_api_gateway_integration.api_to_sqs`
* **The Justification:** Traditional architectures place a Lambda function between the API and the Queue. At the exact millisecond of a major ticket drop, thousands of concurrent requests can hit the endpoint, causing Lambda throttle errors (`TooManyRequestsException`). By utilizing a direct AWS Service Integration, API Gateway pushes data straight to SQS via an IAM role over AWS's internal network fabric, providing virtually infinite ingestion scaling.

### 2. Dual-Lambda Pipeline & State Isolation
* **The Implementation:** `aws_lambda_function.ingest_processor` AND `aws_lambda_function.stream_router`
* **The Justification:** To maintain a clean Microservices boundary, the system separates write-operations from event-routing:
  * **Lambda 1** is a high-speed worker dedicated *solely* to draining the SQS Queue and updating ticket seat inventories in **Amazon DynamoDB**.
  * **Lambda 2** is completely decoupled; it wakes up asynchronously *only* when the database successfully commits a transaction (`NEW_IMAGE` stream event). It normalizes the data into a schema-validated domain event (`Ticket_Purchased`) and publishes it to **Amazon EventBridge**. This prevents downstream latency (like email generation or payment clearing) from bottlenecking the core ordering database.

### 3. Edge-Scoped Threat Absorption
* **The Implementation:** `aws_wafv2_web_acl` with `scope = "CLOUDFRONT"`
* **The Justification:** Attaching WAF to a regional Application Load Balancer or API Gateway forces the local AWS region to absorb the computing cost of checking and dropping millions of automated scraper bot requests. Configuring the WAF scope to CloudFront leverages AWS's global network of hundreds of Edge Points of Presence (PoPs), absorbing and neutralizing distributed denial-of-service (DDoS) and automated traffic closest to the attacker.

---

## 🚀 Deployment & Validation

### Prerequisites
* Terraform CLI (>= 1.5.0)
* Configured AWS CLI with appropriate administrative/least-privilege credentials.

### Execution Steps
1. # Initialize Directory & Providers:
   ```bash
   terraform init
2. # Generate a Mock Lambda Deployment Package - need to create a placeholder zip 
    zip dummy_payload.zip main.tf
   # This simply compresses main.tf file into an archive named dummy_payload.zip. This satisfies Terraform's requirement for a deployment package 
   # during the initial infrastructure build. 
3. # Formats code to standard HashiCorp configuration rules
     terraform fmt
4. # Validates syntax, block structures, and reference attributes
     terraform validate 
5. # Review the Execution Plan
     terraform plan
6. # Apply and Deploy to AWS
     terraform apply
7. # Cleaning up (optional)
     terraform destroy

---

## 🧪 Testing & Validation

### 1. Testing the API Gateway & Message Ingestion

Send a test order to the API Gateway endpoint to verify that requests are routed correctly through CloudFront, API Gateway, and into the SQS FIFO queue:

```bash
curl -X POST "https://YOUR_WORKING_DOMAIN.cloudfront.net/order?v=2" \
  -H "Content-Type: application/json" \
  -d '{"seat_id": "12B", "user_id": "user_london_01", "price": 85.00}'
```

**What to look for:**  
A successful HTTP `200` or `202` response confirms the payload was ingested by API Gateway and forwarded directly to the SQS FIFO queue via the compute-bypass pattern. Check the queue metrics in the AWS Console (SQS → your-queue → Monitoring) to see the message count increment.

---

### 2. Testing Deduplication (The 5-Minute Window)

SQS FIFO queues use content-based deduplication within a 5-minute deduplication interval. This guarantees that duplicate requests (e.g., accidental double-clicks by a user) do not result in double-bookings.

**The Test**  
Fire the exact same curl command twice in a row within 5 seconds:

```bash
# First request (should succeed)
curl -X POST "https://YOUR_WORKING_DOMAIN.cloudfront.net/order?v=2" \
  -H "Content-Type: application/json" \
  -d '{"seat_id": "12B", "user_id": "user_london_01", "price": 85.00}'

# Identical second request within 5 seconds (should be deduplicated)
curl -X POST "https://YOUR_WORKING_DOMAIN.cloudfront.net/order?v=2" \
  -H "Content-Type: application/json" \
  -d '{"seat_id": "12B", "user_id": "user_london_01", "price": 85.00}'
```

**What to look for:**  
Both requests return a `200`/`202` status (API Gateway does not reject the duplicate), but the SQS queue will only contain **one** message. Check the **NumberOfMessagesSent** vs **NumberOfMessagesReceived** CloudWatch metrics — the deduplication count will show that only the first message was enqueued. This is the zero-double-booking guarantee in action.

---

### 3. Testing Message Attributes (Filtering & Routing)

Each order placed into the queue carries structured metadata in the form of **Message Attributes**. Downstream microservices (e.g., Billing, Seating Reservation) can inspect these attributes instantly to decide whether to consume or ignore a message — without needing to parse the JSON body.

**The Test**  
Use the AWS CLI to peek into the queue and prove that your metadata is cleanly separated from your JSON body text:

```bash
aws sqs receive-message \
  --queue-url https://sqs.your-region.amazonaws.com/your-account-id/your-queue-name.fifo \
  --message-attribute-names QueueType
```

**What to look for:**  
In the terminal output, you will see your raw JSON sitting inside the `"Body"` block, but right below it, you will see a structured `"MessageAttributes"` object isolating `"QueueType": "OrderPlacement"`. Your downstream microservices can read this attribute instantly to decide if this message should go to the billing system or the seating reservation engine.