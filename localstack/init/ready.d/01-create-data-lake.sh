#!/bin/bash
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
ACCOUNT_ID="000000000000"
RAW_BUCKET="lake-raw"
PROCESSED_BUCKET="lake-processed"
QUEUE_NAME="lake-file-events"

awslocal s3 mb "s3://${RAW_BUCKET}"
awslocal s3 mb "s3://${PROCESSED_BUCKET}"

QUEUE_URL="$(awslocal sqs create-queue \
  --queue-name "${QUEUE_NAME}" \
  --query 'QueueUrl' \
  --output text)"
QUEUE_ARN="$(awslocal sqs get-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' \
  --output text)"
RAW_BUCKET_ARN="arn:aws:s3:::${RAW_BUCKET}"

python3 - "${RAW_BUCKET_ARN}" "${QUEUE_ARN}" "${REGION}" "${ACCOUNT_ID}" <<'PY'
import json
import sys

bucket_arn, queue_arn, region, account_id = sys.argv[1:]
policy = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {"Service": "s3.amazonaws.com"},
            "Action": "sqs:SendMessage",
            "Resource": queue_arn,
            "Condition": {
                "ArnLike": {"aws:SourceArn": bucket_arn},
                "StringEquals": {"aws:SourceAccount": account_id},
            },
        }
    ],
}
with open("/tmp/sqs-attributes.json", "w", encoding="utf-8") as file:
    json.dump({"Policy": json.dumps(policy)}, file)

notification = {
    "QueueConfigurations": [
        {
            "Id": "raw-bucket-to-sqs",
            "QueueArn": queue_arn,
            "Events": ["s3:ObjectCreated:*"],
        }
    ]
}
with open("/tmp/s3-notification.json", "w", encoding="utf-8") as file:
    json.dump(notification, file)

environment = {
    "Variables": {
        "PROCESSED_BUCKET": "lake-processed",
        "AWS_DEFAULT_REGION": region,
        "AWS_ENDPOINT_URL": "http://host.docker.internal:4566",
    }
}
with open("/tmp/lambda-environment.json", "w", encoding="utf-8") as file:
    json.dump(environment, file)
PY

awslocal sqs set-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --attributes file:///tmp/sqs-attributes.json
awslocal s3api put-bucket-notification-configuration \
  --bucket "${RAW_BUCKET}" \
  --notification-configuration file:///tmp/s3-notification.json

python3 - <<'PY'
import zipfile

with zipfile.ZipFile("/tmp/lake-file-processor.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    archive.write("/opt/lambda-src/handler.py", "handler.py")
PY

awslocal lambda create-function \
  --function-name lake-file-processor \
  --runtime python3.12 \
  --handler handler.lambda_handler \
  --role "arn:aws:iam::${ACCOUNT_ID}:role/lambda-execution-role" \
  --zip-file fileb:///tmp/lake-file-processor.zip \
  --timeout 30 \
  --environment file:///tmp/lambda-environment.json

awslocal lambda create-event-source-mapping \
  --function-name lake-file-processor \
  --event-source-arn "${QUEUE_ARN}" \
  --batch-size 1 \
  --enabled

echo "Data lake local inicializado: s3://${RAW_BUCKET} -> SQS -> Lambda -> s3://${PROCESSED_BUCKET}"
