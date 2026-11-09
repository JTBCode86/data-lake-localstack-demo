import json
import os
from urllib.parse import quote, unquote_plus

import boto3


def lambda_handler(event, context):
    s3 = boto3.client(
        "s3",
        endpoint_url=os.environ.get("AWS_ENDPOINT_URL"),
        region_name=os.environ.get("AWS_DEFAULT_REGION", "us-east-1"),
    )
    processed_bucket = os.environ["PROCESSED_BUCKET"]
    processed_count = 0

    for queue_record in event.get("Records", []):
        notification = json.loads(queue_record["body"])
        for record in notification.get("Records", []):
            source = record.get("s3")
            if source is None:
                raise ValueError("SQS message does not contain an S3 event")

            source_bucket = source["bucket"]["name"]
            source_key = unquote_plus(source["object"]["key"])
            metadata = {
                "source_bucket": source_bucket,
                "source_key": source_key,
                "size": source["object"].get("size"),
                "event_name": record.get("eventName"),
                "event_time": record.get("eventTime"),
            }
            output_key = (
                f"events/{quote(source_bucket, safe='')}/"
                f"{quote(source_key, safe='/')}.json"
            )
            s3.put_object(
                Bucket=processed_bucket,
                Key=output_key,
                Body=json.dumps(metadata, ensure_ascii=False).encode("utf-8"),
                ContentType="application/json",
            )
            processed_count += 1

    return {"processed_events": processed_count}
