#!/bin/bash
# =============================================
# WebGLビルドを deploy ブランチに push するスクリプト
#
# 開発者がUnityビルド後にこのスクリプトを実行すると、
# ビルド成果物が deploy ブランチにコミット＆プッシュされる。
# 担当者は git pull するだけでビルドを取得できる。
#
# 使い方:
#   bash aws-setup/push-build.sh <ビルドフォルダのパス>
#   例: bash aws-setup/push-build.sh ./Builds
#
# =============================================
set -e

# =============================================
# 引数チェック
# =============================================
BUILD_DIR="${1}"
if [ -z "$BUILD_DIR" ]; then
  echo "ERROR: ビルドフォルダのパスを指定してください"
  echo "  使い方: bash aws-setup/push-build.sh <ビルドフォルダ>"
  echo "  例:     bash aws-setup/push-build.sh ./Builds"
  exit 1
fi

# 絶対パスに変換（ブランチ切替後も参照できるように）
BUILD_DIR="$(cd "$BUILD_DIR" 2>/dev/null && pwd)" || {
  echo "ERROR: フォルダが見つかりません: $1"
  exit 1
}

if [ ! -f "$BUILD_DIR/index.html" ]; then
  echo "ERROR: index.html が見つかりません。正しいWebGLビルドフォルダですか？"
  echo "  指定されたパス: $BUILD_DIR"
  exit 1
fi

# =============================================
# スクリプトの場所からプロジェクトディレクトリを特定
# =============================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

REPO_ROOT="$(cd "$PROJECT_DIR" && git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "ERROR: git リポジトリ内で実行してください"
  exit 1
}

# プロジェクトのリポジトリ内相対パス（例: Sabake_osakana）
PROJECT_REL="${PROJECT_DIR#$REPO_ROOT/}"

cd "$REPO_ROOT"

ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
DEPLOY_BRANCH="deploy"

# aws-setup/ と AWS_README.yaml の絶対パスを保存
AWS_SETUP_DIR="$PROJECT_DIR/aws-setup"
AWS_README="$PROJECT_DIR/AWS_README.yaml"
ENV_JSON_EXAMPLE="$PROJECT_DIR/Assets/StreamingAssets/env.json.example"

echo "=========================================="
echo " WebGLビルド → deploy ブランチに push"
echo " ビルド元:   $BUILD_DIR"
echo " プロジェクト: $PROJECT_REL"
echo " ブランチ:   $ORIGINAL_BRANCH → $DEPLOY_BRANCH"
echo "=========================================="

# =============================================
# 作業ディレクトリの変更をチェック
# =============================================
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  echo ""
  echo "WARNING: コミットされていない変更があります。"
  echo "  deploy ブランチへの切り替え前に stash します。"
  git stash push -m "push-build: auto stash before deploy branch switch"
  STASHED=1
else
  STASHED=0
fi

# =============================================
# deploy ブランチの準備
# =============================================
echo ""
echo "[1/5] deploy ブランチを準備..."

DEPLOY_EXISTS=$(git branch --list "$DEPLOY_BRANCH")
DEPLOY_REMOTE_EXISTS=$(git ls-remote --heads origin "$DEPLOY_BRANCH" 2>/dev/null | wc -l)

if [ -n "$DEPLOY_EXISTS" ]; then
  git checkout "$DEPLOY_BRANCH"
  if [ "$DEPLOY_REMOTE_EXISTS" -gt 0 ]; then
    git pull origin "$DEPLOY_BRANCH" --no-edit || true
  fi
elif [ "$DEPLOY_REMOTE_EXISTS" -gt 0 ]; then
  git checkout -b "$DEPLOY_BRANCH" "origin/$DEPLOY_BRANCH"
else
  echo "  deploy ブランチを新規作成（orphan）..."
  git checkout --orphan "$DEPLOY_BRANCH"
  git rm -rf . 2>/dev/null || true
fi

echo "  OK: deploy ブランチに切り替え完了"

# =============================================
# 既存ファイルをクリーンアップ
# =============================================
echo ""
echo "[2/5] ファイルを準備..."

rm -rf webgl-build/
mkdir -p webgl-build/
rm -rf aws-setup/

# =============================================
# ファイルをコピー（絶対パスを使用）
# =============================================
echo ""
echo "[3/5] ビルド成果物をコピー..."

# SimulationBuild, server.py 等はWebGLに不要なので除外
for item in "$BUILD_DIR"/*; do
  basename="$(basename "$item")"
  case "$basename" in
    SimulationBuild|server.py) continue ;;
    *) cp -r "$item" webgl-build/ ;;
  esac
done

# env.json.example を配置
if [ ! -f webgl-build/StreamingAssets/env.json.example ]; then
  mkdir -p webgl-build/StreamingAssets
  if [ -f "$ENV_JSON_EXAMPLE" ]; then
    cp "$ENV_JSON_EXAMPLE" webgl-build/StreamingAssets/
  else
    cat > webgl-build/StreamingAssets/env.json.example << 'ENVEOF'
{
  "environment": "production",
  "leaderboardApiUrl": "https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com/prod"
}
ENVEOF
  fi
fi

echo "  OK: webgl-build/ にコピー完了"

# aws-setup/ をコピー
echo ""
echo "[4/5] aws-setup/ と README をコピー..."

mkdir -p aws-setup/
for f in "$AWS_SETUP_DIR"/*; do
  [ -f "$f" ] && cp "$f" aws-setup/
done
# .env.example もコピー
[ -f "$AWS_SETUP_DIR/.env.example" ] && cp "$AWS_SETUP_DIR/.env.example" aws-setup/

# AWS_README.yaml をコピー
[ -f "$AWS_README" ] && cp "$AWS_README" .

echo "  OK: aws-setup/ と AWS_README.yaml をコピー完了"

# =============================================
# .gitignore 作成（deploy ブランチ用）
# =============================================
cat > .gitignore << 'GIEOF'
# deploy ブランチでは webgl-build/, aws-setup/, AWS_README.yaml のみ管理
# それ以外は全て除外

# 環境設定（担当者がローカルで作成）
aws-setup/.env
webgl-build/StreamingAssets/env.json

# Unity プロジェクト（deploy ブランチには不要）
*/Temp/
*/Library/
*/Logs/
*/obj/
*/UserSettings/

# OS
.DS_Store
Thumbs.db
GIEOF

# =============================================
# コミット & プッシュ
# =============================================
echo ""
echo "[5/5] コミット & プッシュ..."

git add webgl-build/ aws-setup/ AWS_README.yaml .gitignore
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

if git diff --cached --quiet 2>/dev/null; then
  echo "  変更なし（ビルドが前回と同じ）"
else
  git commit -m "build: WebGL update ${TIMESTAMP}"
  git push origin "$DEPLOY_BRANCH"
  echo "  OK: deploy ブランチに push 完了"
fi

# =============================================
# 元のブランチに戻る
# =============================================
git checkout "$ORIGINAL_BRANCH"

if [ "$STASHED" -eq 1 ]; then
  git stash pop
  echo "  stash を復元しました"
fi

echo ""
echo "=========================================="
echo " 完了！"
echo " 担当者に以下を伝えてください:"
echo "   初回: git clone --branch deploy --single-branch <URL>"
echo "   更新: git pull && bash aws-setup/deploy-webgl.sh"
echo "=========================================="
