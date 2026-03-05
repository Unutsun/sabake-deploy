#!/bin/bash
# =============================================
# さばけ！おさかな WebGLビルド デプロイスクリプト
#
# Unity WebGLビルドをS3にアップロードし、
# CloudFrontキャッシュを無効化する。
#
# 使い方:
#   bash deploy-webgl.sh [ビルドフォルダのパス]
#   例: bash deploy-webgl.sh ./SabakeBuild
#
# deploy ブランチから実行する場合、引数なしで OK:
#   git pull && bash aws-setup/deploy-webgl.sh
#   → 自動的に ../webgl-build を参照
#
# Unity側のビルド設定:
#   Compression Format: Gzip（デフォルト）
#   Decompression Fallback: OFF
#
# ビルドフォルダの構造（例）:
#   SabakeBuild/
#   ├── index.html
#   ├── StreamingAssets/
#   │   └── env.json          ← API URL設定
#   ├── Build/
#   │   ├── SabakeBuild.loader.js
#   │   ├── SabakeBuild.data.gz
#   │   ├── SabakeBuild.framework.js.gz
#   │   └── SabakeBuild.wasm.gz
#   └── TemplateData/
#       ├── style.css
#       └── ...
# =============================================
set -e

# .env 読み込み用のスクリプトディレクトリ（先に計算）
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 引数チェック（引数なしの場合、deploy ブランチ構造の ../webgl-build を使用）
BUILD_DIR="${1:-${SCRIPT_DIR}/../webgl-build}"

if [ -z "$BUILD_DIR" ]; then
  echo "ERROR: ビルドフォルダのパスを指定してください"
  echo "  使い方: bash deploy-webgl.sh [ビルドフォルダ]"
  echo "  例:     bash deploy-webgl.sh ./SabakeBuild"
  echo "  ※ 引数なしの場合、../webgl-build を参照します"
  exit 1
fi

if [ ! -d "$BUILD_DIR" ]; then
  echo "ERROR: フォルダが見つかりません: $BUILD_DIR"
  exit 1
fi

if [ ! -f "$BUILD_DIR/index.html" ]; then
  echo "ERROR: index.html が見つかりません。正しいWebGLビルドフォルダですか？"
  echo "  指定されたパス: $BUILD_DIR"
  exit 1
fi

# .env 読み込み
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
echo " WebGLビルド デプロイ"
echo " ビルド: $BUILD_DIR"
echo " S3:     $BUCKET"
echo "=========================================="

# =============================================
# 1. env.json 存在チェック
# =============================================
echo ""
echo "[1/4] env.json チェック..."

if [ -f "$BUILD_DIR/StreamingAssets/env.json" ]; then
  echo "  OK: env.json 存在"
  cat "$BUILD_DIR/StreamingAssets/env.json"
else
  echo "  WARNING: StreamingAssets/env.json が見つかりません！"
  echo "  ランキング機能が動作しません。"
  echo "  env.json.example を参考に作成してください。"
  read -p "  続行しますか？ (y/N): " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "  中断しました"
    exit 1
  fi
fi

# =============================================
# 2. 通常ファイルをアップロード（html, css, png等）
# =============================================
echo ""
echo "[2/4] 通常ファイルをアップロード..."

# まず全体を同期（Content-Typeは自動判定）
# env.json はS3上で直接管理するため、--delete で消さない
aws s3 sync "$BUILD_DIR" "s3://${BUCKET}" \
  --region $REGION \
  --exclude "*.gz" \
  --exclude "*.br" \
  --exclude "StreamingAssets/env.json" \
  --delete

echo "  OK: 通常ファイルアップロード完了"

# =============================================
# 3. 圧縮ファイルを正しいヘッダー付きでアップロード
#    Gzip (.gz) と Brotli (.br) の両方に対応
# =============================================
echo ""
echo "[3/4] 圧縮ファイルをアップロード..."

upload_compressed() {
  local file="$1"
  local content_type="$2"
  local content_encoding="$3"
  local s3_key="${file#$BUILD_DIR/}"

  aws s3 cp "$file" "s3://${BUCKET}/${s3_key}" \
    --region $REGION \
    --content-type "$content_type" \
    --content-encoding "$content_encoding" \
    --quiet

  echo "  $s3_key → $content_type ($content_encoding)"
}

# --- Gzip (.gz) ---
find "$BUILD_DIR" -name "*.wasm.gz" | while read f; do
  upload_compressed "$f" "application/wasm" "gzip"
done
find "$BUILD_DIR" -name "*.data.gz" | while read f; do
  upload_compressed "$f" "application/octet-stream" "gzip"
done
find "$BUILD_DIR" -name "*.js.gz" | while read f; do
  upload_compressed "$f" "application/javascript" "gzip"
done
find "$BUILD_DIR" -name "*.symbols.json.gz" | while read f; do
  upload_compressed "$f" "application/octet-stream" "gzip"
done

# --- Brotli (.br) ---
find "$BUILD_DIR" -name "*.wasm.br" | while read f; do
  upload_compressed "$f" "application/wasm" "br"
done
find "$BUILD_DIR" -name "*.data.br" | while read f; do
  upload_compressed "$f" "application/octet-stream" "br"
done
find "$BUILD_DIR" -name "*.js.br" | while read f; do
  upload_compressed "$f" "application/javascript" "br"
done
find "$BUILD_DIR" -name "*.symbols.json.br" | while read f; do
  upload_compressed "$f" "application/octet-stream" "br"
done

echo "  OK: Gzipファイルアップロード完了"

# =============================================
# 4. CloudFrontキャッシュ無効化
# =============================================
echo ""
echo "[4/4] CloudFrontキャッシュ無効化..."

if [ -n "$DIST_ID" ] && [ "$DIST_ID" != "None" ]; then
  INVALIDATION_ID=$(aws cloudfront create-invalidation \
    --distribution-id $DIST_ID \
    --paths "/*" \
    --query 'Invalidation.Id' --output text)
  echo "  OK: キャッシュ無効化開始 ($INVALIDATION_ID)"
  echo "  ※ 反映に数分かかる場合があります"
else
  echo "  スキップ（CLOUDFRONT_DIST_ID が .env に未設定）"
  echo "  手動で無効化する場合:"
  echo "    aws cloudfront create-invalidation --distribution-id <ID> --paths '/*'"
fi

# =============================================
# 完了
# =============================================
CLOUDFRONT_DOMAIN="${CLOUDFRONT_DOMAIN:-}"

echo ""
echo "=========================================="
echo " デプロイ完了！"
echo "=========================================="
if [ -n "$CLOUDFRONT_DOMAIN" ]; then
  echo ""
  echo "  URL: https://${CLOUDFRONT_DOMAIN}"
fi
echo ""
echo "  ※ CloudFrontの反映に数分かかる場合があります"
echo "=========================================="
