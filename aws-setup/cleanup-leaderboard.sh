#!/bin/bash
# =============================================
# さばけ！おさかな ランキングAPI 削除スクリプト
# やり直したい場合にこちらを先に実行
#
# .env から設定を読み込み
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

REGION="${AWS_REGION:?'.env に AWS_REGION を設定してください'}"
TABLE_NAME="${TABLE_NAME:?'.env に TABLE_NAME を設定してください'}"
FUNCTION_NAME="${FUNCTION_NAME:?'.env に FUNCTION_NAME を設定してください'}"
ROLE_NAME="${ROLE_NAME:?'.env に ROLE_NAME を設定してください'}"
API_NAME="${API_NAME:?'.env に API_NAME を設定してください'}"

echo "=========================================="
echo " ランキングAPI リソース削除"
echo " リージョン: $REGION"
echo "=========================================="

# API Gateway削除
echo "[1/4] API Gateway 削除..."
API_ID=$(aws apigatewayv2 get-apis --region $REGION \
  --query "Items[?Name=='${API_NAME}'].ApiId" --output text 2>/dev/null || echo "")
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  aws apigatewayv2 delete-api --api-id $API_ID --region $REGION
  echo "  削除: $API_ID"
else
  echo "  スキップ（見つからない）"
fi

# Lambda削除
echo "[2/4] Lambda 削除..."
aws lambda delete-function --function-name $FUNCTION_NAME --region $REGION 2>/dev/null \
  && echo "  削除: $FUNCTION_NAME" \
  || echo "  スキップ（見つからない）"

# IAMロール削除
echo "[3/4] IAM ロール削除..."
aws iam delete-role-policy --role-name $ROLE_NAME --policy-name SabakeDynamoDBAccess 2>/dev/null || true
aws iam detach-role-policy --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role --role-name $ROLE_NAME 2>/dev/null \
  && echo "  削除: $ROLE_NAME" \
  || echo "  スキップ（見つからない）"

# DynamoDB削除
echo "[4/4] DynamoDB テーブル削除..."
aws dynamodb delete-table --table-name $TABLE_NAME --region $REGION 2>/dev/null \
  && echo "  削除: $TABLE_NAME" \
  || echo "  スキップ（見つからない）"

echo ""
echo "=========================================="
echo " 削除完了！再セットアップ可能です"
echo "=========================================="
