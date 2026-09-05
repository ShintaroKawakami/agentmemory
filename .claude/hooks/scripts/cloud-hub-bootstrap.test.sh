#!/usr/bin/env bash
# [2026-09-05][test] cloud-hub-bootstrap.sh の単体テスト（11ケース）。
# 背景:
#   - ユーザー依頼意図:
#     1) CLAUDE_CODE_REMOTE 未設定・false（ローカル）では常に無音・exit 0 であること。
#     2) [2026-09-05 Codex レビュー4回目・Critical 対応後の確定設計] 配置元は常に
#        「固定URLから取得した上流ツリー全体」であり、$PJ_ROOT/../AGENT-HUB 等のローカルな
#        「AGENT-HUB らしきもの」は存在しても内容を一切読まない・参照しない・比較もしない
#        こと。決り改変された skills/SKILL.md・docs/project-registry.yaml・
#        .git/config の insteadOf 仕込みを持つ偽の隣接ディレクトリが存在していても、
#        実際に配置される内容は固定URL先（テストでは GIT_CONFIG_GLOBAL で差し替えた
#        本物の upstream）の内容とだけ一致すること。
#     3) 固定URLへの fetch が失敗する（オフライン・credential無し・AGENT-HUB未添付）場合は、
#        ローカルに有効な候補が存在するかに関わらず、常に添付案内のみで bootstrap を
#        呼ばず exit 0 すること。
#     4) basename が project-registry.yaml と 0件・複数件一致する場合は、ブロックせず
#        警告して bootstrap を呼ばないこと。
#     5) PyYAML が無い環境では grep/sed 相当のプレーンテキスト解決（フロースタイル・
#        ブロックスタイルの canonical_name 両方）へフォールバックし、その旨を警告すること。
#   - 守るべき業務ルール: どのケースでも exit 0 を明示的にアサートする（SessionStart hook は
#     常に非ブロック）。実際の AGENT-HUB リポジトリや harness-resolver.py には依存させず、
#     mktemp で作った偽の「upstream」ローカルリポジトリ + スタブ cloud-bootstrap-skills.py で
#     隔離する。固定 URL（https://github.com/ShintaroKawakami/AGENT-HUB.git）の解決先は、
#     hook 側に環境変数の上書き口を作らず、git 標準機能（GIT_CONFIG_GLOBAL で指す一時
#     global config の url.<local>.insteadOf）だけで差し替える。信頼境界はコンテナ環境
#     （global git config・環境変数）であり、リポジトリの中身ではないため、テストでの
#     差し替えはコンテナ環境側（GIT_CONFIG_GLOBAL）で行うのが正しい（hook 側 CaD 参照）。
#     偽の隣接ディレクトリ自身の .git/config への insteadOf 混入（Test 5）は git config
#     コマンドではなくファイルへの直接追記で再現する（候補が攻撃者の入力そのものであることを
#     模す）。「実際に配置される内容が本物の upstream と一致する」は、スタブ
#     cloud-bootstrap-skills.py が自分の実行元ツリー（--hub-root で渡されたパス）配下の
#     skills/example-skill/SKILL.md をそのまま読んで標準出力へ印字する仕組みで検証する
#     （読み出したマーカー文字列が「本物」か「偽の隣接ディレクトリの改変版」かで
#     配置元を判別できる）。PyYAML 不在は python3 をラップしたフェイクバイナリ
#     （`-c 'import yaml'` だけ失敗させ、他の呼び出しは実 python3 へ委譲）でシミュレートする
#     （実 python3 環境からアンインストールしない）。
#   - 他案不採用理由: 実 AGENT-HUB を上流として使う案は、harness-resolver.py のフル実行に
#     依存しテストが遅く・脆くなるため不採用。偽 upstream + スタブ script で
#     hook 自体の fetch・展開・PJ名解決ロジックだけを検証する。
# 対応: mktemp -d で隔離した PJ_ROOT / 偽 upstream フィクスチャを都度作り、11ケースを検証する。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="$SCRIPT_DIR/cloud-hub-bootstrap.sh"
FIXED_UPSTREAM_URL="https://github.com/ShintaroKawakami/AGENT-HUB.git"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloud-hub-bootstrap-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

REAL_PYTHON3="$(command -v python3)"
[ -n "$REAL_PYTHON3" ] || fail "セットアップ: python3 が見つからない"

GIT_ENV=(-c user.email=test@example.com -c user.name=test)

# 偽の「upstream」リポジトリを1つ作る（skills/example-skill/SKILL.md +
# registries/harness-manifest.yaml + docs/project-registry.yaml +
# スタブ cloud-bootstrap-skills.py を持つ通常 git repo、main ブランチにコミット済み）。
# 全テストで共有する「本物」役。スタブは自分の実行元ツリー配下の SKILL.md を読んで
# 印字するため、テストは印字内容で配置元の真偽を判別できる。
UPSTREAM_SRC="$TMP_DIR/upstream-src"
mkdir -p "$UPSTREAM_SRC/skills/example-skill" "$UPSTREAM_SRC/registries" "$UPSTREAM_SRC/docs" "$UPSTREAM_SRC/scripts"
cat > "$UPSTREAM_SRC/skills/example-skill/SKILL.md" <<'MD'
GENUINE-UPSTREAM-SKILL-MARKER
MD
cat > "$UPSTREAM_SRC/registries/harness-manifest.yaml" <<'YAML'
version: 2
materialization_contract:
  version: 1
YAML
cat > "$UPSTREAM_SRC/docs/project-registry.yaml" <<'YAML'
project_taxonomy:
  version: 2
  projects:
    jtt-system: {canonical_name: jtt-system, type: dev}
    agent-hub: {canonical_name: AGENT-HUB, type: hub}
    dup-shared: {canonical_name: dup-shared, type: dev}
    dup-b: {canonical_name: dup-shared, type: dev}
    google-review:
      canonical_name: google-review
      type: dev
projects:
  agent-hub:
    stack: [Markdown]
YAML
cat > "$UPSTREAM_SRC/scripts/cloud-bootstrap-skills.py" <<'PY'
#!/usr/bin/env python3
import sys
from pathlib import Path

args = sys.argv[1:]
hub_root = None
if "--hub-root" in args:
    hub_root = Path(args[args.index("--hub-root") + 1])

marker_path = (hub_root / "skills" / "example-skill" / "SKILL.md") if hub_root else None
if marker_path is not None and marker_path.is_file():
    marker = marker_path.read_text(encoding="utf-8").strip()
else:
    marker = "NO-MARKER-FOUND"

print("[stub] argv:", args)
print("[stub] skill-marker:", marker)
sys.exit(0)
PY
chmod +x "$UPSTREAM_SRC/scripts/cloud-bootstrap-skills.py"
git -C "$UPSTREAM_SRC" init -q -b main
git -C "$UPSTREAM_SRC" add -A
git "${GIT_ENV[@]}" -C "$UPSTREAM_SRC" commit -q -m "init"

# hook 内固定 URL を上記 upstream-src へ差し替える一時 global config。
# hook 側には環境変数の上書き口を作らない（hook 側 CaD 参照）。テスト側だけが
# GIT_CONFIG_GLOBAL でコンテナの git 設定を差し替える。
GOOD_GITCONFIG="$TMP_DIR/global-gitconfig-good"
cat > "$GOOD_GITCONFIG" <<EOF
[url "file://$UPSTREAM_SRC"]
	insteadOf = $FIXED_UPSTREAM_URL
EOF

# fetch 自体が失敗する状況を再現する（存在しないローカルパスへ誤誘導）。
BROKEN_GITCONFIG="$TMP_DIR/global-gitconfig-broken"
cat > "$BROKEN_GITCONFIG" <<EOF
[url "file://$TMP_DIR/does-not-exist"]
	insteadOf = $FIXED_UPSTREAM_URL
EOF

# 偽の隣接ディレクトリ（$PJ_ROOT/../AGENT-HUB）を、upstream-src とは別内容の
# 「攻撃者が完全に制御している」リポジトリとして作る。SKILL.md・project-registry.yaml を
# 改変し、自身の .git/config に insteadOf まで仕込む（git config コマンドではなく
# ファイルへの直接追記で再現する）。この偽ディレクトリはどのテストでも hook から
# 一切参照されないはずであることを Test 5 で確認する。
# $1 = 偽ディレクトリを置く親ディレクトリの絶対パス。
make_malicious_decoy_sibling() {
  local parent="$1"
  local decoy="$parent/AGENT-HUB"
  mkdir -p "$decoy/skills/example-skill" "$decoy/registries" "$decoy/docs" "$decoy/scripts"
  cat > "$decoy/skills/example-skill/SKILL.md" <<'MD'
EVIL-INJECTED-SKILL-MARKER
MD
  cp "$UPSTREAM_SRC/registries/harness-manifest.yaml" "$decoy/registries/harness-manifest.yaml"
  cat > "$decoy/docs/project-registry.yaml" <<'YAML'
project_taxonomy:
  version: 2
  projects:
    jtt-system: {canonical_name: jtt-system, type: dev}
YAML
  cp "$UPSTREAM_SRC/scripts/cloud-bootstrap-skills.py" "$decoy/scripts/cloud-bootstrap-skills.py"
  chmod +x "$decoy/scripts/cloud-bootstrap-skills.py"
  git -C "$decoy" init -q -b main
  git "${GIT_ENV[@]}" -C "$decoy" add -A
  git "${GIT_ENV[@]}" -C "$decoy" commit -q -m "attacker controlled decoy"
  # 候補自身の .git/config へ insteadOf を仕込む（1〜3回目レビューで塞いだ経路が
  # 今回の設計変更後も無害であることの回帰確認）。
  cat >> "$decoy/.git/config" <<EOF
[url "file://$decoy"]
	insteadOf = $FIXED_UPSTREAM_URL
EOF
}

# PyYAML を「無い」ことにする python3 スタブを PATH の先頭に置く。
# `-c 'import yaml'` の呼び出しだけ exit 1、それ以外は実 python3 へ委譲する
# （委譲先は絶対パスを埋め込むため、PATH 経由の再帰は起きない）。
make_no_yaml_fake_bin() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/python3" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-c" ] && printf '%s' "\$2" | grep -q "import yaml"; then
  exit 1
fi
exec "$REAL_PYTHON3" "\$@"
EOF
  chmod +x "$fake_bin/python3"
}

# --- Test 1: CLAUDE_CODE_REMOTE 未設定 → 完全無音・exit 0 ---
PJ1="$TMP_DIR/pj1"
mkdir -p "$PJ1"
OUT="$(CLAUDE_PROJECT_DIR="$PJ1" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 1: exit 0 にならない（exit=${EXIT}）"
[ -z "$OUT" ] || fail "Test 1: ローカルでは無音であるべき: $OUT"

# --- Test 2: CLAUDE_CODE_REMOTE=false（true以外）→ 無音・exit 0 ---
OUT="$(CLAUDE_CODE_REMOTE=false CLAUDE_PROJECT_DIR="$PJ1" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 2: exit 0 にならない（exit=${EXIT}）"
[ -z "$OUT" ] || fail "Test 2: CLAUDE_CODE_REMOTE!=true では無音であるべき: $OUT"

# --- Test 3: 固定URLへの fetch が失敗する（credential無し・AGENT-HUB未添付相当）→
#     ローカルに何も無くても添付案内のみ・exit 0（bootstrap は呼ばれない） ---
PJ3="$TMP_DIR/pj3-fetch-fails"
mkdir -p "$PJ3"
OUT="$(GIT_CONFIG_GLOBAL="$BROKEN_GITCONFIG" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PJ3" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 3: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "AGENT-HUB の取得に失敗しました" || fail "Test 3: 添付案内が出ない: $OUT"
echo "$OUT" | grep -q "添付してください" || fail "Test 3: 添付手順が案内に無い: $OUT"
echo "$OUT" | grep -q "\[stub\]" && fail "Test 3: fetch失敗なのに bootstrap script が呼ばれている: $OUT" || true

# --- Test 4: 固定URLへの fetch が失敗する状態で、ローカルに完全に有効な
#     隣接ディレクトリ（$PJ_ROOT/../AGENT-HUB、改変なし）が存在していても、
#     それを配置元として使わず、やはり添付案内のみになること
#     （ローカル候補はもはや一切参照されない設計であることの確認）---
PJ4_BASE="$TMP_DIR/pj4-fetch-fails-with-local"
mkdir -p "$PJ4_BASE"
git clone -q "$UPSTREAM_SRC" "$PJ4_BASE/AGENT-HUB"
mkdir -p "$PJ4_BASE/jtt-system"
OUT="$(GIT_CONFIG_GLOBAL="$BROKEN_GITCONFIG" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PJ4_BASE/jtt-system" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 4: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "AGENT-HUB の取得に失敗しました" || fail "Test 4: ローカル候補があっても fetch 失敗時は案内になるべき: $OUT"
echo "$OUT" | grep -q "\[stub\]" && fail "Test 4: fetch失敗なのに bootstrap script が呼ばれている（ローカル候補が使われた疑い）: $OUT" || true

# --- Test 5: [2026-09-05 Codex レビュー4回目・Critical 回帰テスト] 固定URLへの fetch は
#     成功し、かつローカルに「SKILL.md・project-registry.yaml を改変し、自身の
#     .git/config に insteadOf まで仕込んだ」攻撃者制御の偽隣接ディレクトリが
#     存在していても、実際に --hub-root として渡され配置される内容は
#     本物の upstream（GIT_CONFIG_GLOBAL 経由）の SKILL.md と一致し、
#     偽ディレクトリの内容（EVIL-INJECTED-SKILL-MARKER）は一切混入しないこと ---
PJ5_BASE="$TMP_DIR/pj5-decoy-present"
make_malicious_decoy_sibling "$PJ5_BASE"
mkdir -p "$PJ5_BASE/jtt-system"
OUT="$(GIT_CONFIG_GLOBAL="$GOOD_GITCONFIG" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PJ5_BASE/jtt-system" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 5: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "project: jtt-system" || fail "Test 5: PJ名が解決されない: $OUT"
echo "$OUT" | grep -q "GENUINE-UPSTREAM-SKILL-MARKER" || fail "Test 5: 配置元が本物の upstream になっていない: $OUT"
echo "$OUT" | grep -q "EVIL-INJECTED-SKILL-MARKER" && fail "Test 5: 偽の隣接ディレクトリの内容が混入している（重大な回帰）: $OUT" || true
echo "$OUT" | grep -q -- "--hub-root', '.*/cloud-hub-bootstrap\." || fail "Test 5: --hub-root が hook 自身の一時ディレクトリ配下になっていない: $OUT"
echo "$OUT" | grep -qF -- "--hub-root', '${PJ5_BASE}" && fail "Test 5: --hub-root がローカル候補ディレクトリを指している（重大な回帰）: $OUT" || true

# --- Test 6: basename が大文字小文字違いでも一致する（案件: JTT-System） ---
PJ6="$TMP_DIR/case-insensitive"
mkdir -p "$PJ6/JTT-System"
OUT="$(GIT_CONFIG_GLOBAL="$GOOD_GITCONFIG" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PJ6/JTT-System" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 6: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "project: jtt-system" || fail "Test 6: 大文字小文字無視の照合ができていない: $OUT"

# --- Test 7: basename が project-registry.yaml のどのキー/canonical_nameにも一致しない
#     → bootstrap を呼ばず警告して exit 0 ---
PJ7="$TMP_DIR/no-match"
mkdir -p "$PJ7/totally-unknown-project"
OUT="$(GIT_CONFIG_GLOBAL="$GOOD_GITCONFIG" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PJ7/totally-unknown-project" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 7: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "一意に照合できませんでした" || fail "Test 7: 未一致の警告が出ない: $OUT"
echo "$OUT" | grep -q "\[stub\]" && fail "Test 7: 未一致なのに bootstrap script が呼ばれている: $OUT" || true

# --- Test 8: basename が複数キーの canonical_name に一致（曖昧）
#     → bootstrap を呼ばず警告して exit 0 ---
PJ8="$TMP_DIR/ambiguous"
mkdir -p "$PJ8/dup-shared"
OUT="$(GIT_CONFIG_GLOBAL="$GOOD_GITCONFIG" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PJ8/dup-shared" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 8: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "一意に照合できませんでした" || fail "Test 8: 曖昧一致の警告が出ない: $OUT"
echo "$OUT" | grep -q "\[stub\]" && fail "Test 8: 曖昧一致なのに bootstrap script が呼ばれている: $OUT" || true

# --- Test 9: CLAUDE_PROJECT_DIR 未設定時は pwd をPJ_ROOTとして使う ---
PJ9="$TMP_DIR/pwd-fallback/jtt-system"
mkdir -p "$PJ9"
OUT="$(cd "$PJ9" && unset CLAUDE_PROJECT_DIR && GIT_CONFIG_GLOBAL="$GOOD_GITCONFIG" CLAUDE_CODE_REMOTE=true bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 9: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "project: jtt-system" || fail "Test 9: CLAUDE_PROJECT_DIR 未設定時に pwd へフォールバックしない: $OUT"

# --- Test 10: PyYAML 不在 → grep/sed 相当の簡易解決へフォールバックし、警告付きで
#     フロースタイル（jtt-system）を解決できる ---
FAKE_BIN="$TMP_DIR/fake-bin-no-yaml"
make_no_yaml_fake_bin "$FAKE_BIN"

PJ10="$TMP_DIR/no-yaml-flow"
mkdir -p "$PJ10/jtt-system"
OUT="$(PATH="$FAKE_BIN:$PATH" GIT_CONFIG_GLOBAL="$GOOD_GITCONFIG" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PJ10/jtt-system" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 10: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "PyYAML が見つからないため" || fail "Test 10: PyYAML無し警告が出ない: $OUT"
echo "$OUT" | grep -q "project: jtt-system" || fail "Test 10: フロースタイルのフォールバック解決ができない: $OUT"

# --- Test 11: PyYAML 不在 → grep/sed 相当の簡易解決で、警告付きで
#     ブロックスタイル（google-review）を解決できる ---
PJ11="$TMP_DIR/no-yaml-block"
mkdir -p "$PJ11/google-review"
OUT="$(PATH="$FAKE_BIN:$PATH" GIT_CONFIG_GLOBAL="$GOOD_GITCONFIG" CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$PJ11/google-review" bash "$TARGET_SCRIPT" 2>&1)"
EXIT=$?
[ "$EXIT" -eq 0 ] || fail "Test 11: exit 0 にならない（exit=${EXIT}）"
echo "$OUT" | grep -q "PyYAML が見つからないため" || fail "Test 11: PyYAML無し警告が出ない: $OUT"
echo "$OUT" | grep -q "project: google-review" || fail "Test 11: ブロックスタイルのフォールバック解決ができない: $OUT"

echo "PASS: cloud-hub-bootstrap"
exit 0
