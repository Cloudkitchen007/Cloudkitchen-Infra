import json
import boto3
import os
import uuid
from botocore.config import Config

region = os.environ.get('AWS_REGION', 'ap-south-1')
s3 = boto3.client('s3', region_name=region, endpoint_url=f"https://s3.{region}.amazonaws.com", config=Config(signature_version='s3v4'))
BUCKET = os.environ['BUCKET_NAME']

def handler(event, context):
    body = json.loads(event.get('body', '{}'))
    filename = body.get('filename', f'testimonial-{uuid.uuid4()}.webm')
    content_type = body.get('contentType', 'video/webm')
    
    key = f"testimonials/{filename}"
    url = s3.generate_presigned_url(
        ClientMethod='put_object',
        Params={
            'Bucket': BUCKET,
            'Key': key,
            'ContentType': content_type
        },
        ExpiresIn=300
    )
    
    return {
        'statusCode': 200,
        'headers': {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': '*'
        },
        'body': json.dumps({'url': url, 'key': key})
    }