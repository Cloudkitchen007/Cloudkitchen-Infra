import json
import boto3
import os

sns = boto3.client('sns')
TOPIC_ARN = os.environ['TOPIC_ARN']

def handler(event, context):
    for record in event.get('Records', []):
        bucket = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        message = f"New testimonial uploaded:\nBucket: {bucket}\nFile: {key}"
        sns.publish(TopicArn=TOPIC_ARN, Message=message, Subject='New Testimonial')
    return {'statusCode': 200}