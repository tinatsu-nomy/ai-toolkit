# AI Toolkit rootless 運用ガイド

このフォークで追加した rootless(Docker コンテナプロセスを非 root で実行する)構成の運用ドキュメントです。

対象: `docker-compose.rootless.yml` + `docker/Dockerfile.rootless`

---

## 1. ファイル構成

| ファイル | 役割 |
|---|---|
| `docker/Dockerfile.rootless` | 公式イメージ `ostris/aitoolkit:latest` 上で uid/gid に降格し、root 前提の `/start.sh` を捨てて UI を直接起動するイメージ定義 |
| `docker-compose.rootless.yml` | rootless 運用向けのサービス定義(ポート・イメージ名・コンテナ名を環境変数化) |
| `.env.example` | 設定サンプル(`cp .env.example .env` で使う。`.env` は gitignore 済み) |

### `.env` 設定項目

| 変数 | 既定値 | 説明 |
|---|---|---|
| `APP_UID` / `APP_GID` | `1000` | rootless イメージの実行 uid/gid。ホストのユーザーに合わせる(`id -u` / `id -g`) |
| `AI_TOOLKIT_AUTH` | `password` | UI ログインパスワード。**本番では必ず変更** |
| `AI_TOOLKIT_PORT` | `8675` | UI のホスト側公開ポート(コンテナ内は 8675 固定) |
| `AI_TOOLKIT_IMAGE` | `aitoolkit-rootless:latest` | ビルド対象イメージ名 |
| `AI_TOOLKIT_CONTAINER` | `ai-toolkit-rootless` | コンテナ名(同一ホストでの住み分け用) |

`docker compose` は起動ディレクトリの `.env` を自動で読み込むため、通常の操作に環境変数の接頭辞は不要です。

---

## 2. 日常操作

すべてリポジトリルート(`docker-compose.rootless.yml` と `.env` がある場所)で実行します。

```bash
# 初回ビルド + 起動
docker compose -f docker-compose.rootless.yml up -d --build

# 状態・ログ確認
docker compose -f docker-compose.rootless.yml ps
docker logs -f ai-toolkit-rootless   # .env の AI_TOOLKIT_CONTAINER の値(シェルでは .env が読まれないため直書き)

# 停止 / 完全削除(バインドマウント済みのデータはホスト側に残る)
docker compose -f docker-compose.rootless.yml stop
docker compose -f docker-compose.rootless.yml down
```

UI: `http://localhost:${AI_TOOLKIT_PORT:-8675}`(パスワードは `AI_TOOLKIT_AUTH`)

### データの場所(バインドマウント)

| ホスト側 | コンテナ内 | 内容 |
|---|---|---|
| `./aitk_db.db` | `/app/ai-toolkit/aitk_db.db` | ジョブ・設定の SQLite DB |
| `./datasets` | `/app/ai-toolkit/datasets` | 学習データ |
| `./output` | `/app/ai-toolkit/output` | 学習出力(ホストユーザー所有で作られる) |
| `./config` | `/app/ai-toolkit/config` | 学習設定 yaml |
| `~/.cache/huggingface/hub` | `/home/ubuntu/.cache/huggingface/hub` | HF モデルキャッシュ |

---

## 3. イメージ更新(アップストリーム追従)

```bash
docker pull ostris/aitoolkit:latest
docker compose -f docker-compose.rootless.yml build --pull --no-cache
docker compose -f docker-compose.rootless.yml up -d
```

注意: `Dockerfile.rootless` のベース(公式イメージ)は upstream のコードを含みます。
**フォーク独自の変更を反映したい場合は**、`docker/Dockerfile` の clone URL をフォークへ変更したフルビルドが必要です(`build_and_push_docker` 参照)。

---

## 4. 本番展開手順

```bash
# 展開先は他のコンテナ運用と揃えて /opt/containers/ai-toolkit
mkdir -p /opt/containers/ai-toolkit/{docker,datasets,output,config} && cd /opt/containers/ai-toolkit
touch aitk_db.db
cp <repo>/.env.example .env
# .env を本番値へ編集: AI_TOOLKIT_AUTH(必須)/ AI_TOOLKIT_PORT /
#   AI_TOOLKIT_CONTAINER / AI_TOOLKIT_IMAGE / APP_UID / APP_GID
# compose の build は context: . に対し docker/Dockerfile.rootless を参照するため
# docker/ ディレクトリが必要
cp <repo>/docker/Dockerfile.rootless docker/
cp <repo>/docker-compose.rootless.yml .

# ファイル名が既定(docker-compose.yml)でないため -f の指定が必須
docker compose -f docker-compose.rootless.yml up -d --build

# 初回のみ DB マイグレーション
# (.env は docker compose にしか読み込まれないため、シェルではコンテナ名を直書きするか
#   `export $(grep -v '^#' .env | xargs)` で読み込む)
docker exec ai-toolkit-rootless sh -c "cd /app/ai-toolkit/ui && npm run update_db"
docker restart ai-toolkit-rootless
```

---

## 5. 注意事項(実運用で判明した事項)

1. **SQLite WAL によるデータ消失リスク**: bind mount した `aitk_db.db` の兄弟ファイル
   `aitk_db.db-wal`(未 checkpoint のテーブル・データを含む)はコンテナ層側に作られるため、
   **コンテナ再作成・再ビルド時に失われます**。
   `up -d --force-recreate`・イメージ更新の前は必ず `aitk_db.db` をバックアップしてください。
2. **NVIDIA ドライバ要件**: ベースイメージが cu130 wheels のため **ドライバ 580 以上** が必要
   (`nvidia-smi` の Driver Version で確認)。
3. **ポート**: 変更できるのはホスト側公開ポートのみ(アプリがコンテナ内 8675 でリッスン固定)。
   同一ホストで複数立てる場合は `.env` の PORT / CONTAINER / IMAGE で住み分けます。
4. **rootless**: UI・cron ワーカー・学習ジョブは uid 1000 で動作し、`output/` の生成物は
   ホストユーザー所有になります。`docker/start.sh` の SSH ブートストラップ(PUBLIC_KEY)は
   root 前提のため rootless 構成では無効です。
5. **初回起動のテーブル不存在エラー**: 空の `aitk_db.db` をマウントした場合、マイグレーション
   前 (`npm run update_db`) はログに `The table main.Queue does not exist` が出力され続けます。
   マイグレーション後、再起動で解消します。
