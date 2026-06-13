# High-Frequency Global Ticketing Engine (Enterprise-Scale IaC)

This repository contains a production-ready, highly resilient Infrastructure-as-Code (Terraform) blueprint for a global, high-concurrency ticket ordering engine. It is architected specifically to handle instantaneous, massive traffic spikes (e.g., major concert ticket drops) while guaranteeing zero double-bookings, robust bot mitigation at the edge, and asynchronous downstream fulfillment.

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
1. **Initialize Directory & Providers:**
   ```bash
   terraform init