# AI Toolkit rootless 運用ガイド

この構成はコンテナ内のUI・ワーカー・学習ジョブを非rootで実行します。
Dockerデーモン自体をrootless化する設定ではありません。

## 初回起動

リポジトリルートで、実行ユーザーとして準備します。

```bash
cp .env.example .env
# .env: APP_UID/APP_GID を id -u / id -g に合わせ、
# AI_TOOLKIT_AUTH にログインパスワードを設定してください。
mkdir -p data cache/huggingface datasets output config
docker compose -f docker-compose.rootless.yml up -d --build
docker compose -f docker-compose.rootless.yml logs -f
```

保存先は設定したAPP_UID/APP_GIDで書き込める必要があります。
既存ディレクトリや別ユーザー所有のデータは、管理者が所有者・権限を確認してください。
イメージ内のchownはホストのbind mountには適用されません。

起動時にDBスキーマを更新し、成功した場合にUIとワーカーを起動します。
既定のUI URLは http://localhost:8675 です。

## 保存先

| ホスト | コンテナ | 内容 |
|---|---|---|
| ./data | /data | DB本体、WAL、SHM |
| ./cache/huggingface | /cache/huggingface | モデルキャッシュ |
| ./datasets | /app/ai-toolkit/datasets | 学習データ |
| ./output | /app/ai-toolkit/output | 学習出力 |
| ./config | /app/ai-toolkit/config | 学習設定 |

アプリ既定のDBパスは /data/aitk_db.db へのシンボリックリンクです。
HF_CACHE_DIRに既存のHugging Faceキャッシュディレクトリの絶対パスを指定できます。
例えば /home/example/.cache/huggingface を指定します（hubの親ディレクトリ）。

## 旧構成からのDB移行

旧コンテナを削除・再作成する前に実施してください。
実行中の学習・キャプション処理を終了し、UIを含む書き込み元を停止します。
旧コンテナのWALが失われる前に、SQLiteのbackup APIで整合したコピーを作ります。

```bash
# コンテナ名を変更している場合は読み替えます。
# コピー先が存在しないことを確認してから実行します。
docker exec ai-toolkit-rootless python -c '
import sqlite3
from pathlib import Path
target = Path("/app/ai-toolkit/output/aitk_db.pre-rootless-migration.db")
if target.exists():
    raise SystemExit("Backup already exists; preserve it before retrying")
with sqlite3.connect("file:/app/ai-toolkit/aitk_db.db?mode=rw", uri=True) as src:
    with sqlite3.connect(target) as dst:
        src.backup(dst)
        result = dst.execute("PRAGMA integrity_check").fetchall()
        if result != [("ok",)]:
            raise SystemExit(result)
'
# 上のバックアップが成功した場合のみ続行します。
docker compose -f docker-compose.rootless.yml stop
mkdir -p data cache/huggingface
test ! -e data/aitk_db.db
# 上のtestが成功した場合のみコピーします。
cp -n output/aitk_db.pre-rootless-migration.db data/aitk_db.db
docker compose -f docker-compose.rootless.yml up -d --build
```

バックアップ取得から停止まで、UIや学習ジョブによる書き込みを再開しないでください。
backup APIは旧コンテナ内のDBとWALを参照し、整合したDBをoutputに保存します。
旧コンテナとバックアップは移行結果の確認まで保持します。

## 更新と日常操作

更新前に学習と書き込みを終了してサービスを正常停止し、
dataディレクトリ全体のバックアップを取得してください。
起動時のスキーマ更新にも備え、バックアップは別の場所に保持します。

```bash
docker compose -f docker-compose.rootless.yml stop
# ここで data ディレクトリ全体をバックアップ
docker compose -f docker-compose.rootless.yml build --pull
docker compose -f docker-compose.rootless.yml up -d
docker compose -f docker-compose.rootless.yml logs -f
```

ベースは公式の ostris/aitoolkit:latest です。ローカルのアプリソースは取り込みません。
検証済みイメージを固定する場合はDockerfile.rootlessのBASE_IMAGEをdigest付き参照に変更します。
GPU利用にはベースイメージのCUDAに対応するNVIDIAドライバが必要です。
SSHブートストラップはこの構成では実行しません。

## 適用後の確認

- 空の保存先から起動し、UIとジョブ登録が動作すること。
- APP_UID=1000以外でも保存先に書き込めること。
- DBアクセス中にDB本体とWAL/SHMが /data に作られること。
- ジョブ登録後にコンテナを再作成してもデータが保持されること。
- モデルキャッシュが再利用され、GPU学習を開始できること。
