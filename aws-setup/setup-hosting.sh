#!/bin/bash
# =============================================
# さばけ！おさかな WebGLホスティング セットアップ
# S3 + CloudFront（HTTPS）
#
# 事前準備:
#   1. .env に S3_BUCKET_NAME を設定済み
#   2. setup-leaderboard.sh を実行済み（API URL取得済み）
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
BUCKET="${S3_BUCKET_NAME:?'.env に S3_BUCKET_NAME を設定してください'}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region $REGION)

echo "=========================================="
echo " さばけ！おさかな ホスティング セットアップ"
echo " リージョン: $REGION"
echo " バケット名: $BUCKET"
echo "=========================================="

# =============================================
# 1. S3バケット作成
# =============================================
echo ""
echo "[1/4] S3バケット作成..."

aws s3api create-bucket \
  --bucket $BUCKET \
  --region $REGION \
  --create-bucket-configuration LocationConstraint=$REGION \
  --output text 2>/dev/null \
  && echo "  OK: $BUCKET 作成完了" \
  || echo "  スキップ（既に存在）"

# パブリックアクセスブロック（CloudFront経由のみアクセス可能にする）
aws s3api put-public-access-block \
  --bucket $BUCKET \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false

echo "  パブリックアクセスブロック設定完了"

# =============================================
# 2. CloudFront OAC 作成
# =============================================
echo ""
echo "[2/4] CloudFront OAC 作成..."

OAC_NAME="sabake-oac"

# 既存OACチェック
OAC_ID=$(aws cloudfront list-origin-access-controls --query \
  "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id" --output text 2>/dev/null || echo "")

if [ -z "$OAC_ID" ] || [ "$OAC_ID" = "None" ]; then
  OAC_ID=$(aws cloudfront create-origin-access-control \
    --origin-access-control-config "{
      \"Name\": \"${OAC_NAME}\",
      \"Description\": \"OAC for Sabake Osakana\",
      \"SigningProtocol\": \"sigv4\",
      \"SigningBehavior\": \"always\",
      \"OriginAccessControlOriginType\": \"s3\"
    }" \
    --query 'OriginAccessControl.Id' --output text)
  echo "  OK: OAC作成 ($OAC_ID)"
else
  echo "  スキップ（既存OAC使用: $OAC_ID）"
fi

# =============================================
# 3. CloudFront ディストリビューション作成
# =============================================
echo ""
echo "[3/4] CloudFront ディストリビューション作成..."

S3_ORIGIN="${BUCKET}.s3.${REGION}.amazonaws.com"

DIST_CONFIG=$(cat << DIST_EOF
{
  "CallerReference": "sabake-$(date +%s)",
  "Comment": "Sabake Osakana WebGL Game",
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "S3-${BUCKET}",
        "DomainName": "${S3_ORIGIN}",
        "OriginAccessControlId": "${OAC_ID}",
        "S3OriginConfig": {
          "OriginAccessIdentity": ""
        }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "S3-${BUCKET}",
    "ViewerProtocolPolicy": "redirect-to-https",
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"]
    },
    "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
    "Compress": false
  },
  "Enabled": true,
  "PriceClass": "PriceClass_200",
  "CustomErrorResponses": {
    "Quantity": 1,
    "Items": [
      {
        "ErrorCode": 403,
        "ResponsePagePath": "/index.html",
        "ResponseCode": "200",
        "ErrorCachingMinTTL": 10
      }
    ]
  }
}
DIST_EOF
)

# Compress: false にする（Unity側で既にGzip済みのため二重圧縮を防止）

DIST_ID=$(aws cloudfront create-distribution \
  --distribution-config "$DIST_CONFIG" \
  --query 'Distribution.Id' --output text)

DIST_DOMAIN=$(aws cloudfront get-distribution \
  --id $DIST_ID \
  --query 'Distribution.DomainName' --output text)

echo "  OK: ディストリビューション作成"
echo "  Distribution ID: $DIST_ID"
echo "  ドメイン: https://${DIST_DOMAIN}"

# =============================================
# 4. S3バケットポリシー設定（CloudFrontからのみアクセス許可）
# =============================================
echo ""
echo "[4/4] S3バケットポリシー設定..."

cat > /tmp/bucket-policy.json << POLICY_EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontServicePrincipal",
      "Effect": "Allow",
      "Principal": {
        "Service": "cloudfront.amazonaws.com"
      },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${BUCKET}/*",
      "Condition": {
        "StringEquals": {
          "AWS:SourceArn": "arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"
        }
      }
    }
  ]
}
POLICY_EOF

aws s3api put-bucket-policy \
  --bucket $BUCKET \
  --policy file:///tmp/bucket-policy.json

echo "  OK: バケットポリシー設定完了"

# =============================================
# 完了
# =============================================
echo ""
echo "=========================================="
echo " ホスティングセットアップ完了！"
echo "=========================================="
echo ""
echo "  CloudFront URL: https://${DIST_DOMAIN}"
echo "  Distribution ID: $DIST_ID"
echo "  S3バケット: $BUCKET"
echo ""
echo "  ▼ 次のステップ:"
echo "  1. Unity で WebGL ビルド"
echo "  2. bash deploy-webgl.sh <ビルドフォルダのパス>"
echo "     例: bash deploy-webgl.sh ./SabakeBuild"
echo ""
echo "  ※ CloudFrontの反映に5-10分かかる場合があります"
echo "=========================================="

# .env に追記
if ! grep -q "CLOUDFRONT_DIST_ID" "$ENV_FILE" 2>/dev/null; then
  echo "" >> "$ENV_FILE"
  echo "# --- 自動追記（setup-hosting.sh） ---" >> "$ENV_FILE"
  echo "CLOUDFRONT_DIST_ID=\"$DIST_ID\"" >> "$ENV_FILE"
  echo "CLOUDFRONT_DOMAIN=\"$DIST_DOMAIN\"" >> "$ENV_FILE"
  echo ""
  echo "  [INFO] .env に CLOUDFRONT_DIST_ID, CLOUDFRONT_DOMAIN を追記しました"
fi
