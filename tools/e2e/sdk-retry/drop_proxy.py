#!/usr/bin/env python3
# issue #94 で作成
"""athena-local の手前で「応答だけを落とす」TCP の代理。

SDK のリトライを誘発するために、目印（MARKER）を含む StartQueryExecution のリクエストは
上流（athena-local）に届けて処理させたうえで、応答をクライアントに返さずに接続を閉じる。
最初の DROP_COUNT 回だけ落とし、それ以降と目印の無いリクエストはそのまま中継する。
「サーバは受け取って実行したが、クライアントには届かなかった」という、冪等化が要る状況そのもの。

標準エラーに 1 接続 1 行で記録する（落としたか、ClientRequestToken は何だったか）。
verify.sh が読むので形式を変えない:
    proxy: <relay|drop> target=<X-Amz-Target> token=<ClientRequestToken か ->

環境変数:
    LISTEN      待ち受け（既定 127.0.0.1:8096）
    UPSTREAM    転送先（既定 127.0.0.1:8091）
    MARKER      落とす対象の目印（既定 t94-insert。リクエスト本文にこの文字列があるときだけ落とす）
    DROP_COUNT  落とす回数（既定 2）
"""

import json
import os
import re
import socket
import sys
import threading

LISTEN = os.environ.get("LISTEN", "127.0.0.1:8096")
UPSTREAM = os.environ.get("UPSTREAM", "127.0.0.1:8091")
MARKER = os.environ.get("MARKER", "t94-insert").encode()
DROP_COUNT = int(os.environ.get("DROP_COUNT", "2"))

lock = threading.Lock()
dropped = 0


def parse_addr(text):
    host, port = text.rsplit(":", 1)
    return host, int(port)


def read_http_message(sock):
    """ヘッダと Content-Length ぶんの本文を読み切る（HTTP/1.1、chunked は使わない前提）。"""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            return data
        data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    match = re.search(rb"(?i)content-length:\s*(\d+)", head)
    length = int(match.group(1)) if match else 0
    while len(body) < length:
        chunk = sock.recv(65536)
        if not chunk:
            break
        body += chunk
    return head + b"\r\n\r\n" + body


def describe(request):
    head, _, body = request.partition(b"\r\n\r\n")
    target = re.search(rb"(?i)x-amz-target:\s*(\S+)", head)
    target = target.group(1).decode() if target else "-"
    token = "-"
    try:
        token = json.loads(body.decode()).get("ClientRequestToken", "-")
    except (ValueError, AttributeError):
        pass
    return target, token


def handle(client):
    global dropped
    try:
        request = read_http_message(client)
        if not request:
            return
        target, token = describe(request)
        upstream = socket.create_connection(parse_addr(UPSTREAM))
        upstream.sendall(request)
        response = read_http_message(upstream)
        upstream.close()
        with lock:
            drop = MARKER in request and dropped < DROP_COUNT
            if drop:
                dropped += 1
        print(f"proxy: {'drop' if drop else 'relay'} target={target} token={token}", file=sys.stderr, flush=True)
        if not drop:
            client.sendall(response)
    finally:
        client.close()


def main():
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(parse_addr(LISTEN))
    server.listen(64)
    print(f"proxy: listening on {LISTEN} -> {UPSTREAM} (drop first {DROP_COUNT} with {MARKER.decode()!r})", file=sys.stderr, flush=True)
    while True:
        client, _ = server.accept()
        threading.Thread(target=handle, args=(client,), daemon=True).start()


if __name__ == "__main__":
    main()
