---
name: release
description: |
  athena-local の新しい版を出す。版を決めて Cargo.toml・Cargo.lock・README の compose 例・CHANGELOGS.md を 1 コミットで変え、PR をマージしたあと注釈付きタグ `vX.Y.Z` を打って、docker.yml が Docker Hub に amd64 / arm64 のイメージを publish したことを確かめる。
  Use when: 「0.5.0 をリリースして」「リリース作業をして」「タグを打って」「新しい版を出したい」と言われた時。
  NOT for: 機能の実装や修正（→ implement-issue / quick-implement）、CHANGELOG の項目を書くこと（挙動を変えた PR が書く）、Docker イメージの手元でのビルドだけ。
---

# リリース

athena-local の版は Docker Hub のイメージタグ（`aoyagikouhei/athena-local:X.Y.Z`）と同じ番号で、
`CHANGELOGS.md` の節・`Cargo.toml`・README の compose 例が同じ番号を指す（CLAUDE.md の約束）。
コミットに注釈付きタグ `vX.Y.Z` を打つと `.github/workflows/docker.yml` が `linux/amd64` と `linux/arm64` を
ネイティブランナーでビルドし、1 つのマニフェストにまとめて `X.Y.Z`・`X.Y`・`latest` のタグで publish する。
GitHub Release はこれまで作っていない（作るなら別途ユーザーに聞く）。

一度 push したタグは動かさない・消さない（同じ番号のイメージが公開済みになるため）。やり直しは次の番号で行う。

## 入力

| | |
|---|---|
| 必須 | 版の番号 `X.Y.Z`（例: `0.5.0`）。無ければ `[Unreleased]` の中身から提案して確かめる: `Added` か `Changed` があれば minor、`Fixed` だけなら patch（0.x のあいだは major を上げない） |
| 任意 | 「タグまで」「PR まで」（どこで止めるか。既定は publish の確認まで） |

## Step 1: 前提の確認（コードに触る前）

すべてを確かめてから進む。1 つでも外れたら止まって報告する（下の「止まる条件」）。

```bash
git status --short                                  # 空であること
git branch --show-current                           # main であること
git fetch --prune origin && git merge --ff-only origin/main
gh pr list --state open                             # 取り込むべき PR が残っていないか。残っていればユーザーに聞く
gh run list --branch main --workflow ci --limit 1   # 直近の main の CI が success
git tag -l 'v*' | sort -V | tail -1                 # 現在の最新タグ（= 今の版 v0.4.0 など）
grep -n '^version' Cargo.toml                       # 今の版と一致していること
sed -n '/^## \[Unreleased\]/,/^## \[/p' CHANGELOGS.md   # [Unreleased] が空でないこと
```

- 新しい版は今の版より大きいこと。`git tag -l vX.Y.Z` が空であること。
- `[Unreleased]` の各項目が 1〜2 行の箇条書きで docs へリンクしていること（CLAUDE.md の約束。長い説明文が混ざっていたら
  リリースの前に直すよう提案する。この Skill では直さない）。
- issue を立ててブランチを切る（CLAUDE.md の流儀。`gh issue create --title "X.Y.Z をリリースする"` →
  `create-issue-branch` スキルで `main-<番号>`）。ブランチを切った直後に `.claude/issue-notes` が残っていれば消す（CLAUDE.md）。

## Step 2: 版を書き換える（1 コミット）

変えるのは次の 4 ファイルだけ。ほかの docs は版を直書きしていない（README の注記は「the image tag the example pins」と書いてあり、
番号を持たない）。念のため `grep -rn '<今の版>' --include='*.md' --include='*.toml' --include='*.yml' . | grep -v CHANGELOGS.md`
で直書きが増えていないか確かめる。

1. **Cargo.toml**: `version = "X.Y.Z"`。
2. **Cargo.lock**: `tools/dev.sh cargo build` を 1 回走らせて `athena-local` の項の version を追随させる（`--locked` は付けない。
   ほかの依存は動かない。差分が `name = "athena-local"` の直下の 1 行だけであることを `git diff Cargo.lock` で見る）。
3. **README.md**: compose 例の `image: aoyagikouhei/athena-local:X.Y.Z`。
4. **CHANGELOGS.md**:
   - `## [Unreleased]` の直後に空行を挟んで `## [X.Y.Z] - YYYY-MM-DD`（`date +%F`）を入れる。`[Unreleased]` の下は空になる
     （`### Added` などの小見出しは新しい版の節に移る）。
   - 末尾の比較リンクを直す: `[Unreleased]: https://github.com/aoyagikouhei/athena-local/compare/vX.Y.Z...HEAD` に変え、
     その次の行に `[X.Y.Z]: https://github.com/aoyagikouhei/athena-local/compare/v<前の版>...vX.Y.Z` を足す。

検証:

```bash
tools/dev.sh cargo fmt --check
tools/dev.sh cargo clippy --all-targets --locked -- -D warnings
tools/dev.sh cargo test --locked
tools/dev.sh docker build -t aoyagikouhei/athena-local:dev .     # 任意。Dockerfile が壊れていないことを手元で見る（数分かかる）
git diff --stat                                     # 4 ファイル（Cargo.lock を含む）だけ
```

コミットは 1 本。件名は `X.Y.Z にする`（0.4.0 までの慣習）、本文にこの版の要点を 1〜3 行（`[Unreleased]` から拾う）。
push して PR を作る（本文は「版・要点・タグの予定」の 3 行と `Closes #<番号>`）。

## Step 3: マージしてタグを打つ

PR のマージはユーザーが行うか、頼まれたときだけ `gh pr merge <番号> --merge --delete-branch`（CI が success で mergeable のときだけ）。

```bash
git switch main && git fetch --prune origin && git merge --ff-only origin/main
git log --oneline -1                                # マージコミット（Merge pull request #<番号> ...）であること
git tag -a vX.Y.Z -m vX.Y.Z                         # 注釈付きタグ。メッセージは版そのもの（0.3.0・0.4.0 と同じ）
git push origin vX.Y.Z
```

タグはマージコミットに打つ（`X.Y.Z にする` のコミットではなく、main の先端）。`git tag -l vX.Y.Z` が空でないのに打とうとしたら止まる。

## Step 4: publish を確かめる

```bash
gh run list --workflow docker --limit 1             # タグの push で起動していること
gh run watch <run-id> --exit-status                 # build（amd64 / arm64）と merge が success（10 分前後）
docker buildx imagetools inspect aoyagikouhei/athena-local:X.Y.Z   # linux/amd64 と linux/arm64 の 2 つが載っていること
docker buildx imagetools inspect aoyagikouhei/athena-local:latest  # latest と X.Y も同じ digest を指す
```

`docker.yml` の最後のステップ `publish されたマニフェストを確認する` が同じ inspect を CI 側でも行う。手元で `docker pull` して
`docker run --rm aoyagikouhei/athena-local:X.Y.Z` が起動する（`TRINO_URL` 未設定でも listen まで行く）ことを見てもよい。

## Step 5: 報告

- 版、タグ、マージコミット、docker.yml の run の URL、イメージのアーキテクチャ。
- `[Unreleased]` が空になったこと。次の PR から新しい項目が積まれる。

## 止まる条件

- 作業ツリーが汚れている、main にいない、`origin/main` に追いつけない（`ff-only` が失敗）。
- 直近の main の CI が success でない。
- 取り込むべき open の PR がある（ユーザーに聞く。マージを待つか、この版に入れないと決める）。
- `[Unreleased]` が空。
- 版が今の版以下、またはタグ `vX.Y.Z` が既にある。
- `cargo build` で Cargo.lock の差分が `athena-local` の version 以外に及ぶ。
- docker.yml の run が失敗した（secrets `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` の不備、ランナーの不調など）。タグは消さず、
  原因を報告する。ワークフローは `workflow_dispatch` でも起動できるので、原因が一時的なら同じタグで再実行する。

## 参照

- `.github/workflows/docker.yml`（タグの push で publish）、`.github/workflows/ci.yml`
- `docs/dev/development.md` の「リリース」
- 前回のリリース: `git show v0.4.0`（`35db9fa 0.4.0 にする`。CHANGELOGS.md・Cargo.lock・Cargo.toml・README.md の 4 ファイル）
