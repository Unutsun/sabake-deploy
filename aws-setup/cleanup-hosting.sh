#!/bin/bash
# =============================================
# さばけ！おさかな ホスティング削除スクリプト
# S3バケット + CloudFront を削除
# =============================================
set -e

# .env 読み込み
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env ファイルが見つかりません"
  exit 1
fi

source "$ENV_FILE"

REGION="${AWS_REGION:?'.env に AWS_REGION を設定してください'}"
BUCKET="${S3_BUCKET_NAME:?'.env に S3_BUCKET_NAME を設定してください'}"
DIST_ID="${CLOUDFRONT_DIST_ID:-}"

echo "=========================================="
echo " ホスティング リソース削除"
echo "=========================================="

# CloudFront削除
echo "[1/3] CloudFront 削除..."
if [ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ]; then
  # まず無効化
  ETAG=$(aws cloudfront get-distribution --id $DIST_ID \
    --query 'ETag' --output text 2>/dev/null || echo "")

  if [ -n "$ETAG" ] && [ "$ETAG" != "None" ]; then
    # Enabled=false に変更
    CONFIG=$(aws cloudfront get-distribution-config --id $DIST_ID --output json 2>/dev/null)
    UPDATED_CONFIG=$(echo "$CONFIG" | python3 -c "
import sys, json
data = json.load(sys.stdin)
config = data['DistributionConfig']
config['Enabled'] = False
print(json.dumps(config))
" 2>/dev/null || echo "")

    if [ -n "$UPDATED_CONFIG" ]; then
      aws cloudfront update-distribution \
        --id $DIST_ID \
        --distribution-config "$UPDATED_CONFIG" \
        --if-match "$ETAG" > /dev/null 2>&1 || true
      echo "  ディストリビューション無効化中..."
      echo "  ※ 完全削除には無効化完了後に再度このスクリプトを実行"
      echo "  （CloudFrontの無効化に15-20分かかります）"

      # 無効化済みなら削除を試みる
      NEW_ETAG=$(aws cloudfront get-distribution --id $DIST_ID \
        --query 'ETag' --output text 2>/dev/null || echo "")
      STATUS=$(aws cloudfront get-distribution --id $DIST_ID \
        --query 'Distribution.Status' --output text 2>/dev/null || echo "")

      if [ "$STATUS" = "Deployed" ]; then
        aws cloudfront delete-distribution --id $DIST_ID --if-match "$NEW_ETAG" 2>/dev/null \
          && echo "  削除: $DIST_ID" \
          || echo "  無効化待ち中（後で再実行してください）"
      fi
    fi
  fi
else
  echo "  スキップ（CLOUDFRONT_DIST_ID 未設定）"
fi

# OAC削除
echo "[2/3] CloudFront OAC 削除..."
OAC_NAME="sabake-oac"
OAC_ID=$(aws cloudfront list-origin-access-controls --query \
  "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id" --output text 2>/dev/null || echo "")
if [ -n "$OAC_ID" ] && [ "$OAC_ID" != "None" ]; then
  OAC_ETAG=$(aws cloudfront get-origin-access-control --id $OAC_ID \
    --query 'ETag' --output text 2>/dev/null || echo "")
  aws cloudfront delete-origin-access-control --id $OAC_ID --if-match "$OAC_ETAG" 2>/dev/null \
    && echo "  削除: $OAC_ID" \
    || echo "  スキップ（使用中の可能性あり）"
else
  echo "  スキップ（見つからない）"
fi

# S3バケット削除
echo "[3/3] S3バケット削除..."
aws s3 rb "s3://${BUCKET}" --force --region $REGION 2>/dev/null \
  && echo "  削除: $BUCKET" \
  || echo "  スキップ（見つからない or 空でない）"

echo ""
echo "=========================================="
echo " 削除完了"
echo "=========================================="
