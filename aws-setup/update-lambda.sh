#!/bin/bash
# =============================================
# Lambda関数のコードを更新するスクリプト
# CORSヘッダー追加等のコード修正を反映する
# =============================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env ファイルが見つかりません"
  exit 1
fi

source "$ENV_FILE"

REGION="${AWS_REGION:-ap-northeast-1}"
FUNCTION_NAME="${FUNCTION_NAME:-SabakeLeaderboardFunc}"

echo "=========================================="
echo " Lambda関数コード更新"
echo " 関数名: $FUNCTION_NAME"
echo "=========================================="

# Lambda コード作成
cat > /tmp/lambda_function.py << 'LAMBDA_EOF'
import json
import boto3
import os
from datetime import datetime, timezone
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table(os.environ.get('TABLE_NAME', 'SabakeLeaderboard'))


def lambda_handler(event, context):
    method = event.get('requestContext', {}).get('http', {}).get('method', 'GET')

    if method == 'POST':
        return handle_post(event)
    elif method == 'GET':
        return handle_get(event)
    else:
        return response(405, {'error': 'Method not allowed'})


def handle_post(event):
    """スコア登録"""
    try:
        body = json.loads(event.get('body', '{}'))
    except json.JSONDecodeError:
        return response(400, {'error': 'Invalid JSON'})

    player_name = body.get('playerName', '').strip()
    score = body.get('score', 0)

    if not player_name:
        return response(400, {'error': 'playerName is required'})

    timestamp = datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')

    item = {
        'playerName': player_name,
        'timestamp': timestamp,
        'score': score,
        'rank': body.get('rank', ''),
        'clearPercent': body.get('clearPercent', 0)
    }

    table.put_item(Item=item)
    return response(200, {'message': 'Score submitted', 'timestamp': timestamp})


def handle_get(event):
    """スコア取得（上位N件）"""
    params = event.get('queryStringParameters') or {}
    limit = min(int(params.get('limit', 10)), 100)

    result = table.scan()

    items = []
    for item in result.get('Items', []):
        items.append({
            'playerName': item.get('playerName', ''),
            'score': int(item.get('score', 0)),
            'rank': item.get('rank', ''),
            'clearPercent': int(item.get('clearPercent', 0)),
            'timestamp': item.get('timestamp', '')
        })

    items.sort(key=lambda x: x['score'], reverse=True)
    items = items[:limit]

    return response(200, items)


def response(status_code, body):
    """レスポンス生成"""
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json; charset=utf-8',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type'
        },
        'body': json.dumps(body, ensure_ascii=False) if body else ''
    }
LAMBDA_EOF

# ZIP圧縮
cd /tmp && zip -j function.zip lambda_function.py > /dev/null

# Lambda関数コード更新
aws lambda update-function-code \
  --function-name $FUNCTION_NAME \
  --zip-file fileb:///tmp/function.zip \
  --region $REGION \
  --output text --query 'FunctionArn'

echo ""
echo "  OK: Lambda関数コード更新完了"

# 動作確認
echo ""
echo "  動作確認中..."
sleep 2

TEST_RESULT=$(curl -s -D- "https://$(aws apigatewayv2 get-apis --region $REGION --output text --query "Items[?Name=='${API_NAME:-SabakeLeaderboardAPI}'].ApiEndpoint" | head -1)/scores?limit=1" 2>&1 | head -10)
echo "$TEST_RESULT"

if echo "$TEST_RESULT" | grep -q "access-control-allow-origin"; then
  echo ""
  echo "  OK: CORSヘッダー確認完了"
else
  echo ""
  echo "  WARNING: CORSヘッダーが見つかりません。確認してください。"
fi

echo ""
echo "=========================================="
echo " 完了！ランキング機能が有効になりました"
echo "=========================================="
