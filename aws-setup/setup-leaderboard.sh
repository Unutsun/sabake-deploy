#!/bin/bash
# =============================================
# さばけ！おさかな ランキングAPI セットアップ
# AWS CloudShell で実行推奨
#
# 事前準備:
#   cp .env.example .env  で設定ファイルを作成
#   必要に応じてリージョンやリソース名を変更
# =============================================
set -e

# .env 読み込み
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env ファイルが見つかりません"
  echo "  cp .env.example .env で作成してください"
  exit 1
fi

source "$ENV_FILE"

# 必須変数チェック
REGION="${AWS_REGION:?'.env に AWS_REGION を設定してください'}"
TABLE_NAME="${TABLE_NAME:?'.env に TABLE_NAME を設定してください'}"
FUNCTION_NAME="${FUNCTION_NAME:?'.env に FUNCTION_NAME を設定してください'}"
ROLE_NAME="${ROLE_NAME:?'.env に ROLE_NAME を設定してください'}"
API_NAME="${API_NAME:?'.env に API_NAME を設定してください'}"

echo "=========================================="
echo " さばけ！おさかな ランキングAPI セットアップ"
echo " リージョン: $REGION"
echo "=========================================="

# アカウントID取得
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region $REGION)
echo "[1/7] アカウントID: $ACCOUNT_ID"

# =============================================
# 1. DynamoDB テーブル作成
# =============================================
echo ""
echo "[2/7] DynamoDB テーブル作成..."

aws dynamodb create-table \
  --table-name $TABLE_NAME \
  --attribute-definitions \
    AttributeName=id,AttributeType=S \
    AttributeName=gsi_pk,AttributeType=S \
    AttributeName=score,AttributeType=N \
  --key-schema \
    AttributeName=id,KeyType=HASH \
  --global-secondary-indexes \
    '[{
      "IndexName": "ScoreRankIndex",
      "KeySchema": [
        {"AttributeName": "gsi_pk", "KeyType": "HASH"},
        {"AttributeName": "score", "KeyType": "RANGE"}
      ],
      "Projection": {"ProjectionType": "ALL"},
      "ProvisionedThroughput": {"ReadCapacityUnits": 5, "WriteCapacityUnits": 5}
    }]' \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region $REGION \
  --output text --query 'TableDescription.TableStatus'

echo "  テーブル作成待機中..."
aws dynamodb wait table-exists --table-name $TABLE_NAME --region $REGION
echo "  OK: $TABLE_NAME テーブル作成完了"

# =============================================
# 2. IAM ロール作成（Lambda実行用）
# =============================================
echo ""
echo "[3/7] IAM ロール作成..."

# 信頼ポリシー
cat > /tmp/trust-policy.json << 'TRUST_EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUST_EOF

aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document file:///tmp/trust-policy.json \
  --output text --query 'Role.Arn'

# 基本実行ポリシー（CloudWatch Logs）
aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# DynamoDB アクセスポリシー
cat > /tmp/dynamodb-policy.json << DYNAMO_EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:Query",
        "dynamodb:Scan"
      ],
      "Resource": [
        "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}",
        "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}/index/*"
      ]
    }
  ]
}
DYNAMO_EOF

aws iam put-role-policy \
  --role-name $ROLE_NAME \
  --policy-name SabakeDynamoDBAccess \
  --policy-document file:///tmp/dynamodb-policy.json

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "  OK: ロール作成完了"

# IAMロールの伝播を待つ（10秒）
echo "  IAMロール伝播待ち（10秒）..."
sleep 10

# =============================================
# 3. Lambda 関数コード作成
# =============================================
echo ""
echo "[4/7] Lambda 関数作成..."

cat > /tmp/lambda_function.py << LAMBDA_EOF
import json
import boto3
import uuid
from datetime import datetime
from decimal import Decimal

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('${TABLE_NAME}')


def lambda_handler(event, context):
    """メインハンドラー: HTTP APIのメソッドでルーティング"""
    method = event.get('requestContext', {}).get('http', {}).get('method', '')

    if method == 'POST':
        return post_score(event)
    elif method == 'GET':
        return get_scores(event)
    elif method == 'OPTIONS':
        return response(200, '')
    else:
        return response(405, {'error': 'Method not allowed'})


def post_score(event):
    """スコア送信: POST /scores"""
    try:
        body = json.loads(event.get('body', '{}'))
    except (json.JSONDecodeError, TypeError):
        return response(400, {'error': 'Invalid JSON'})

    player_name = body.get('playerName', 'ななし')
    if not player_name:
        player_name = 'ななし'

    item = {
        'id': str(uuid.uuid4()),
        'gsi_pk': 'ALL',
        'playerName': player_name,
        'score': body.get('score', 0),
        'rank': body.get('rank', ''),
        'clearPercent': body.get('clearPercent', 0),
        'timestamp': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    }

    table.put_item(Item=item)

    return response(201, {'message': 'Score submitted', 'id': item['id']})


def get_scores(event):
    """上位スコア取得: GET /scores?limit=N"""
    params = event.get('queryStringParameters') or {}
    try:
        limit = int(params.get('limit', '10'))
    except ValueError:
        limit = 10
    limit = min(max(limit, 1), 50)  # 1-50の範囲に制限

    result = table.query(
        IndexName='ScoreRankIndex',
        KeyConditionExpression='gsi_pk = :pk',
        ExpressionAttributeValues={':pk': 'ALL'},
        ScanIndexForward=False,  # score降順
        Limit=limit
    )

    items = []
    for item in result.get('Items', []):
        items.append({
            'playerName': item.get('playerName', ''),
            'score': int(item.get('score', 0)),
            'rank': item.get('rank', ''),
            'clearPercent': int(item.get('clearPercent', 0)),
            'timestamp': item.get('timestamp', '')
        })

    return response(200, items)


def response(status_code, body):
    """レスポンス生成"""
    return {
        'statusCode': status_code,
        'headers': {
            'Content-Type': 'application/json; charset=utf-8'
        },
        'body': json.dumps(body, ensure_ascii=False) if body else ''
    }
LAMBDA_EOF

# ZIP圧縮
cd /tmp && zip -j function.zip lambda_function.py > /dev/null
cd -

# Lambda関数作成
aws lambda create-function \
  --function-name $FUNCTION_NAME \
  --runtime python3.12 \
  --role $ROLE_ARN \
  --handler lambda_function.lambda_handler \
  --zip-file fileb:///tmp/function.zip \
  --timeout 10 \
  --memory-size 128 \
  --region $REGION \
  --output text --query 'FunctionArn'

LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
echo "  OK: Lambda関数作成完了"

# =============================================
# 4. API Gateway (HTTP API) 作成
# =============================================
echo ""
echo "[5/7] API Gateway (HTTP API) 作成..."

# HTTP API作成（CORS設定込み）
API_ID=$(aws apigatewayv2 create-api \
  --name $API_NAME \
  --protocol-type HTTP \
  --cors-configuration '{
    "AllowOrigins": ["*"],
    "AllowMethods": ["GET", "POST", "OPTIONS"],
    "AllowHeaders": ["Content-Type"],
    "MaxAge": 86400
  }' \
  --region $REGION \
  --output text --query 'ApiId')

echo "  API ID: $API_ID"

# Lambda統合
INTEGRATION_ID=$(aws apigatewayv2 create-integration \
  --api-id $API_ID \
  --integration-type AWS_PROXY \
  --integration-uri $LAMBDA_ARN \
  --payload-format-version "2.0" \
  --region $REGION \
  --output text --query 'IntegrationId')

echo "  Integration ID: $INTEGRATION_ID"

# ルート作成: POST /scores
aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key "POST /scores" \
  --target "integrations/$INTEGRATION_ID" \
  --region $REGION \
  --output text --query 'RouteId'

# ルート作成: GET /scores
aws apigatewayv2 create-route \
  --api-id $API_ID \
  --route-key "GET /scores" \
  --target "integrations/$INTEGRATION_ID" \
  --region $REGION \
  --output text --query 'RouteId'

echo "  OK: ルート作成完了"

# =============================================
# 5. Lambda Permission（API Gatewayからの呼び出し許可）
# =============================================
echo ""
echo "[6/7] Lambda Permission 設定..."

aws lambda add-permission \
  --function-name $FUNCTION_NAME \
  --statement-id AllowAPIGateway \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
  --region $REGION \
  --output text --query 'Statement' > /dev/null

echo "  OK: Permission設定完了"

# =============================================
# 6. ステージ作成（自動デプロイ）
# =============================================
echo ""
echo "[7/7] APIデプロイ..."

aws apigatewayv2 create-stage \
  --api-id $API_ID \
  --stage-name prod \
  --auto-deploy \
  --region $REGION \
  --output text --query 'StageName'

# =============================================
# 完了！
# =============================================
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/prod"

echo ""
echo "=========================================="
echo " セットアップ完了！"
echo "=========================================="
echo ""
echo "  API URL: $API_URL"
echo ""
echo "  ▼ Unity側の設定:"
echo "  Assets/StreamingAssets/env.json を以下の内容に更新:"
echo ""
echo "  {"
echo "    \"environment\": \"production\","
echo "    \"leaderboardApiUrl\": \"$API_URL\""
echo "  }"
echo ""
echo "=========================================="
echo ""
echo "  ▼ テスト用コマンド:"
echo ""
echo "  # スコア送信テスト"
echo "  curl -X POST ${API_URL}/scores \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"playerName\":\"テスト太郎\",\"score\":100,\"rank\":\"たたき級\",\"clearPercent\":85}'"
echo ""
echo "  # ランキング取得テスト"
echo "  curl ${API_URL}/scores?limit=10"
echo ""
echo "=========================================="
