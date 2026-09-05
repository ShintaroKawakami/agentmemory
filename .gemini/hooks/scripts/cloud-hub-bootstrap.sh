#!/usr/bin/env bash
# [2026-09-05][feat] cloud-hub-bootstrap: Claude Code on the web（クラウド）向け SessionStart hook
# 背景:
#   - ユーザー依頼意図: クラウド実行環境（Claude Code on the web、CLAUDE_CODE_REMOTE=true）で
#     セッション開始時に AGENT-HUB のスキルを対象 PJ へ自動的に取り寄せたい。
#     実測根拠: jtt-system ブランチ spike/cloud-hub-probe の docs/spike-cloud-hub-probe.md
#     （2026-09-05・gh api で参照）。
#   - 実測で判明した制約（上記 spike より）:
#     1) クラウドでは PJ が /home/user/<repo> に置かれ、CLAUDE_CODE_REMOTE=true が立つ。
#     2) 単体セッションでは AGENT-HUB の clone は不可（credential がセッションの repo に
#        限定され、add_repo も auto mode 分類器が拒否する）。→ hook からの clone は試みない。
#     3) セッション作成画面で AGENT-HUB を「添付」すると /home/user/AGENT-HUB（PJ の隣）へ
#        自動 clone される。その状態で scripts/cloud-bootstrap-skills.py が exit 0 で機能し、
#        同一セッション内で即座にスキルが認識された（実測: jtt-system で 36 skill 配置）。
#     4) 添付 checkout はセッション専用ブランチで upstream 未設定のため、
#        git pull --ff-only は exit 1 になる（fetch は成功する）。hook からは pull しない。
#     5) spike 第2回: 添付 checkout から固定 URL への fetch は成功する（ネットワーク到達性・
#        credential とも問題なし）。添付されていれば固定 URL への fetch 自体が
#        credential を伴って通る、という構図が実測から読み取れる。
#   - 守るべき業務ルール:
#     1) SessionStart hook は常に exit 0（ブロックしない、情報提供のみ）。
#     2) HUB の git clone は試みない（実測で credential 制約により失敗するため）。
#     3) HUB の正本 writer（sync-runtime-skills.py 等）の身元チェックガードは一切緩めない。
#        本 hook が自前で持つのはクラウド判定・固定 URL からの上流ツリー取得・PJ 名解決
#        （PyYAML 不在時のフォールバック含む）までであり、スキル本体の配置処理は
#        非正本の使い捨て環境専用経路である scripts/cloud-bootstrap-skills.py へ委譲する
#        （独自の配布ロジックは持たない）。
#     4) [2026-09-05 Codex レビュー4回目・Critical 対応後] スキル・設定の配置元は常に
#        「固定 URL から取得した上流ツリー」のみ。PJ 配下・隣接ディレクトリのローカルな
#        AGENT-HUB らしきものは、存在しても内容を読まない・参照しない・比較もしない。
#   - 他案不採用理由:
#     1) hook 自身が AGENT-HUB を git clone する案 → 実測で credential 制約・auto mode
#        分類器の拒否により失敗するため不採用。
#     2) .claude/skills をコミットして配布する案 → 各 PJ の .gitignore で追跡外であり、
#        かつ HUB スキル本文の二重管理（正本ドリフト）を生むため不採用。
#     3) PJ 名を常にディレクトリパスから推測する案 → harness-resolver.py の
#        normalise_project() は「NEVER infers from directory paths」を原則としており、
#        これは変更しない。一方クラウドの使い捨て環境では basename 以外に手掛かりが無いため、
#        本 hook 限定でベストエフォートの basename 照合を行い、0件・複数件時は必ず警告して
#        スキップする（resolver 自体・他の呼び出し元の挙動には影響しない）。
#   - 他案不採用理由（追記・2026-09-05 Codex レビュー1〜3回目・すべて4回目で不採用に変更）:
#     [1回目で採用・2回目で不採用] $PJ_ROOT/../AGENT-HUB または
#     $PJ_ROOT/.agent-hub-cache/AGENT-HUB をローカル候補として探索し、
#     git remote origin が許可 owner/repo と一致する場合だけ採用する案 →
#     origin はローカルの .git/config に書かれた値であり、正規由来の証明にならない
#     （偽の隣接 AGENT-HUB を用意し origin を正規 URL に書き換えるだけで通過する）。
#     [2回目で採用・3回目で不採用] 固定 URL から候補リポ内（git -C <候補> fetch）で
#     fetch し、fetch 成功 + 候補の scripts/・registries/harness-manifest.yaml が
#     FETCH_HEAD と一致することを diff で確認する案 →
#     固定 URL であっても、候補リポ自身の .git/config に書かれた
#     url.<攻撃者URL>.insteadOf が適用されてしまい、fetch 先を攻撃者の偽 upstream
#     （scripts/・harness-manifest.yaml を改変版で揃えたもの）へこっそり差し替えられる。
#     [3回目で採用・4回目で不採用] fetch を候補と無関係な一時 git ディレクトリで行い、
#     候補の .git は読ませない構成にした上で、取得した FETCH_HEAD から
#     scripts/・registries/harness-manifest.yaml だけを参照専用ツリーへ展開し、
#     候補ディレクトリの実ファイルと diff -r（プレーンファイル比較）で比較する案 →
#     insteadOf 経由の差し替えは防げたが、検証対象を scripts/ と
#     registries/harness-manifest.yaml だけに限定していたため、
#     skills/（各 SKILL.md 本文）と docs/project-registry.yaml は未検証のまま
#     候補ディレクトリから直接配置されていた。SKILL.md は「実行されるコードではない」が
#     AI への指示として読まれるため、改変された SKILL.md が対象 PJ へ自動配置される
#     経路が残っていた（Codex 4回目指摘）。
#     検証範囲を skills/・docs/project-registry.yaml にも広げて候補を使い続ける案も
#     検討したが、HUB 側にファイルが増えるたびに「検証対象にまだ何か漏れていないか」を
#     都度洗い出す必要があり、将来にわたって同じ失敗モード（検証範囲の漏れ）を
#     構造的に抱え続ける。ローカル候補を一切信頼せず、常に固定 URL から取得した
#     内容だけを配置元にすれば、この失敗モード自体を消せるため、この設計へ変更した。
#   - 他案不採用理由（追記・2026-09-05 Codex レビュー4回目・確定方針）:
#     4) 検証をスキップする環境変数やフラグを hook に用意する案 → 攻撃者が同じ環境変数を
#        設定できるなら検証自体が無意味になるため不採用。テストで固定 URL の解決先を
#        差し替える必要がある場合は、hook 側にフックを作らず、git 標準機能
#        （GIT_CONFIG_GLOBAL 経由の url.insteadOf 書き換え）で行う。信頼境界はコンテナ環境
#        （global git config・環境変数）であり、リポジトリの中身ではない。コンテナ環境
#        そのものを攻撃者が制御できるなら、この hook に限らずセッション全体が既に危険な
#        状態であり、この hook 単体で防御すべき対象ではない。
#     5) 取得した上流ツリーの一部パスだけを git archive で絞り込む案 →
#        cloud-bootstrap-skills.py・harness-resolver.py が読むファイル集合は将来変わりうる。
#        絞り込みを都度追随させるのは3回目不採用の「検証対象の漏れ」と同じ失敗モードを
#        再導入する。取得コストは shallow (--depth 1) な単一コミットの archive でしかなく、
#        絞り込みで得られる利益より漏れのリスクの方が大きいため、常にツリー全体を展開する。
# 対応: CLAUDE_CODE_REMOTE=true の時だけ発火。候補ディレクトリの探索・検証は一切行わない。
#   毎回、候補と無関係な新規の一時ディレクトリで hook 内固定 URL（FIXED_UPSTREAM_URL）から
#   `git fetch --depth 1 main` を実行し、成功したら `git archive FETCH_HEAD` で
#   取得したコミットのツリー全体を一時ディレクトリへ展開する。この展開先だけを
#   HUB_ROOT として使い、docs/project-registry.yaml から PJ 名を basename 照合
#   （大文字小文字無視）で解決した上で、
#   scripts/cloud-bootstrap-skills.py --project <pj> --project-root <PJ_ROOT>
#   --hub-root <展開先> --runtimes claude を実行する。PJ 名解決は PyYAML があれば
#   厳密パース、無ければ grep/sed 相当のプレーンテキスト解析（簡易解決・要警告）に
#   フォールバックする。fetch が通らない環境（オフライン・credential 無し、または
#   AGENT-HUB が添付されていない）では、スキルは配置されず添付案内だけが出る。

set -uo pipefail

# ローカル（非クラウド）セッションでは常に無音で何もしない。
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PJ_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# hook 内に固定した取得元 URL。ローカルの git 設定（remote / insteadOf 等）は一切経由しない
# （候補ディレクトリを fetch 元にも比較対象にもしないため、経由しようがない構成にする）。
FIXED_UPSTREAM_URL="https://github.com/ShintaroKawakami/AGENT-HUB.git"

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cloud-hub-bootstrap.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

# 固定URLから main を取得し、$TEMP_ROOT/hub へツリー全体を展開する。
#   1) fetch は $TEMP_ROOT/fetch-git という、このセッション内だけの新規 git リポジトリで
#      行う（候補ディレクトリの存在有無・内容に一切依存しない）。
#   2) fetch できたコミットのツリー全体を git archive で展開する。展開先だけを
#      HUB_ROOT として使う（ローカルにある「AGENT-HUB らしきもの」は読まない）。
# 失敗した場合は理由を stderr に書いて return 1 する（呼び出し側が案内へフォールバックする）。
fetch_upstream_tree() {
  local fetch_pid waited fetch_git hub_dir

  fetch_git="$TEMP_ROOT/fetch-git"
  hub_dir="$TEMP_ROOT/hub"
  mkdir -p "$hub_dir"

  if ! git init -q "$fetch_git" >/dev/null 2>&1; then
    echo "検証用の一時 git ディレクトリを初期化できませんでした。" >&2
    return 1
  fi

  (
    export GIT_TERMINAL_PROMPT=0
    export GIT_SSH_COMMAND="ssh -oBatchMode=yes -oConnectTimeout=5"
    exec git -C "$fetch_git" fetch --quiet --depth 1 "$FIXED_UPSTREAM_URL" main
  ) >/dev/null 2>&1 &
  fetch_pid=$!
  waited=0
  while kill -0 "$fetch_pid" 2>/dev/null; do
    if [ "$waited" -ge 100 ]; then
      # 10秒（0.1s x 100）で打ち切り（オフライン・credential 無し・低速回線）。
      kill "$fetch_pid" 2>/dev/null || true
      wait "$fetch_pid" 2>/dev/null || true
      echo "固定URLからの fetch が10秒でタイムアウトしました（オフライン・credential無し・AGENT-HUB未添付の可能性）。" >&2
      return 1
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  if ! wait "$fetch_pid" 2>/dev/null; then
    echo "固定URL ($FIXED_UPSTREAM_URL) からの fetch に失敗しました（オフライン・credential無し・AGENT-HUB未添付の可能性）。" >&2
    return 1
  fi

  if ! git -C "$fetch_git" archive FETCH_HEAD 2>/dev/null | tar -x -C "$hub_dir" 2>/dev/null; then
    echo "上流ツリーを展開できませんでした。" >&2
    return 1
  fi

  if [ ! -f "$hub_dir/scripts/cloud-bootstrap-skills.py" ] \
    || [ ! -d "$hub_dir/skills" ] \
    || [ ! -f "$hub_dir/registries/harness-manifest.yaml" ] \
    || [ ! -f "$hub_dir/docs/project-registry.yaml" ]; then
    echo "上流ツリーに想定するファイルが揃っていません（展開先: $hub_dir）。" >&2
    return 1
  fi

  return 0
}

if ! fetch_upstream_tree; then
  echo "" >&2
  echo "🔍 [cloud-hub-bootstrap] AGENT-HUB の取得に失敗しました。" >&2
  echo "  セッション作成画面の「＋」で ShintaroKawakami/AGENT-HUB を添付してください。" >&2
  echo "  添付されていて固定URLへの fetch が通る環境であれば、次回このhookが" >&2
  echo "  固定URLから直接スキルを取得して自動配置します（ローカルの候補は参照しません）。" >&2
  echo "" >&2
  exit 0
fi

HUB_ROOT="$TEMP_ROOT/hub"

# [2026-09-05][feat] PJ 名解決を PyYAML 厳密パースと grep/sed 相当の簡易解決の2段構えにする。
# 背景: クラウド実行環境での PyYAML 可用性は未確認（cloud-bootstrap-skills.py は
#   harness-resolver.py 経由で yaml に依存し実測で動いたが、本 hook 自身の解決ロジックが
#   同じ前提に乗ってよい保証はない）。python3 -c 'import yaml' が失敗する場合は、
#   HUB_ROOT（固定URLから取得した上流ツリー）の docs/project-registry.yaml の
#   project_taxonomy.projects セクションを grep/sed 相当のプレーンテキスト解析で
#   列挙するフォールバックへ落とす。
# 守るべき業務ルール: フォールバックはフロースタイル（1行 canonical_name）とブロックスタイル
#   （次行以降の canonical_name）の両方を扱うが、想定外の書式は拾えないため、必ず
#   「PyYAML 無しの簡易解決」の警告を出す（degraded path であることを隠さない）。
resolve_project_key_pyyaml() {
  python3 - "$HUB_ROOT" "$PJ_ROOT" <<'PY'
import sys
from pathlib import Path

hub_root = Path(sys.argv[1])
pj_root = Path(sys.argv[2])
basename = pj_root.name.strip().lower()

try:
    import yaml
except ModuleNotFoundError:
    print("PyYAML が見つかりません", file=sys.stderr)
    sys.exit(3)

registry_path = hub_root / "docs" / "project-registry.yaml"
try:
    data = yaml.safe_load(registry_path.read_text(encoding="utf-8")) or {}
except Exception as exc:  # noqa: BLE001 - fail-open で理由を stderr へ
    print(f"project-registry.yaml の読み込みに失敗しました: {exc}", file=sys.stderr)
    sys.exit(3)

projects = ((data.get("project_taxonomy") or {}).get("projects")) or {}
if not isinstance(projects, dict):
    print("project_taxonomy.projects が見つかりません", file=sys.stderr)
    sys.exit(3)

matches: dict[str, None] = {}
for key, profile in projects.items():
    if not isinstance(profile, dict):
        continue
    if str(key).strip().lower() == basename:
        matches[str(key)] = None
        continue
    canonical = profile.get("canonical_name")
    if isinstance(canonical, str) and canonical.strip().lower() == basename:
        matches[str(key)] = None

if len(matches) == 1:
    print(next(iter(matches)))
    sys.exit(0)
if len(matches) == 0:
    print(f"project-registry.yaml に一致するPJが見つかりません（basename: {basename}）", file=sys.stderr)
    sys.exit(1)
print(
    f"project-registry.yaml に複数一致しました（basename: {basename} -> {sorted(matches)}）",
    file=sys.stderr,
)
sys.exit(2)
PY
}

# grep/sed 相当のプレーンテキスト解析フォールバック（PyYAML 不在時）。
# docs/project-registry.yaml の "  projects:"（project_taxonomy.projects、2スペース indent）から
# 次の0-indentキー（"projects:" という別セクション。旧世代の frozen applicable_skills）までを
# 対象範囲とし、4スペース indent のキーと canonical_name（同一行 or 6スペース以上 indent の
# 後続行）を拾って basename と大文字小文字無視で照合する。
resolve_project_key_fallback() {
  local hub_root="$1" pj_root="$2"
  local basename
  basename="$(basename "$pj_root" | tr '[:upper:]' '[:lower:]')"
  local registry="$hub_root/docs/project-registry.yaml"
  if [ ! -f "$registry" ]; then
    echo "project-registry.yaml が見つかりません: $registry" >&2
    return 3
  fi

  local in_section=0
  local pending_key=""
  local -a match_keys=()
  local line key rest canon key_lc canon_lc

  while IFS= read -r line; do
    if [ "$in_section" -eq 0 ]; then
      if [ "$line" = "  projects:" ]; then
        in_section=1
      fi
      continue
    fi
    if [[ "$line" =~ ^[A-Za-z] ]]; then
      break
    fi

    if [ -n "$pending_key" ] && [[ "$line" =~ ^[[:space:]]{6,}canonical_name:[[:space:]]*\"?([A-Za-z0-9_.-]+)\"? ]]; then
      canon="${BASH_REMATCH[1]}"
      canon_lc="$(printf '%s' "$canon" | tr '[:upper:]' '[:lower:]')"
      if [ "$canon_lc" = "$basename" ]; then
        match_keys+=("$pending_key")
      fi
      pending_key=""
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]{4}([A-Za-z0-9_.-]+):(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      pending_key=""
      key_lc="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
      if [[ "$rest" =~ canonical_name:[[:space:]]*\"?([A-Za-z0-9_.-]+)\"? ]]; then
        canon="${BASH_REMATCH[1]}"
        canon_lc="$(printf '%s' "$canon" | tr '[:upper:]' '[:lower:]')"
        if [ "$key_lc" = "$basename" ] || [ "$canon_lc" = "$basename" ]; then
          match_keys+=("$key")
        fi
      elif [[ "$rest" =~ ^[[:space:]]*$ ]]; then
        # ブロックスタイル: canonical_name は後続行にある可能性がある。
        pending_key="$key"
        if [ "$key_lc" = "$basename" ]; then
          match_keys+=("$key")
        fi
      elif [ "$key_lc" = "$basename" ]; then
        match_keys+=("$key")
      fi
      continue
    fi
  done < "$registry"

  # 重複除去（同じキーが key 一致・canonical 一致の両方で入る場合がある）。
  local -a uniq=()
  local m u found
  for m in "${match_keys[@]:-}"; do
    [ -n "$m" ] || continue
    found=0
    for u in "${uniq[@]:-}"; do
      if [ "$u" = "$m" ]; then
        found=1
        break
      fi
    done
    [ "$found" -eq 0 ] && uniq+=("$m")
  done

  if [ "${#uniq[@]}" -eq 1 ]; then
    printf '%s\n' "${uniq[0]}"
    return 0
  fi
  if [ "${#uniq[@]}" -eq 0 ]; then
    echo "project-registry.yaml(簡易解決) に一致するPJが見つかりません（basename: $basename）" >&2
    return 1
  fi
  echo "project-registry.yaml(簡易解決) に複数一致しました（basename: $basename -> ${uniq[*]}）" >&2
  return 2
}

resolve_project_key() {
  if python3 -c 'import yaml' >/dev/null 2>&1; then
    resolve_project_key_pyyaml
    return $?
  fi
  echo "PyYAML が見つからないため、project-registry.yaml を簡易解決（grep/sed 相当）します。" >&2
  resolve_project_key_fallback "$HUB_ROOT" "$PJ_ROOT"
  return $?
}

TMP_ERR="$(mktemp "${TMPDIR:-/tmp}/cloud-hub-bootstrap-resolve.XXXXXX")"
# 注意: 2つ目の `trap ... EXIT` は1つ目を上書きしてしまう（bash の trap は単一ハンドラ）。
# TEMP_ROOT の削除を巻き込むため、両方を1本の trap にまとめて再設定する。
trap 'rm -rf "$TEMP_ROOT"; rm -f "$TMP_ERR"' EXIT

PROJECT_KEY="$(resolve_project_key 2>"$TMP_ERR")"
RESOLVE_EXIT=$?
RESOLVE_WARN="$(cat "$TMP_ERR" 2>/dev/null)"

if [ "$RESOLVE_EXIT" -ne 0 ]; then
  echo "" >&2
  echo "🔍 [cloud-hub-bootstrap] PJ 名を project-registry.yaml と一意に照合できませんでした。" >&2
  [ -n "$RESOLVE_WARN" ] && echo "  $RESOLVE_WARN" >&2
  echo "  スキルは自動配置しません。手動で以下を実行してください:" >&2
  echo "  python3 \"$HUB_ROOT/scripts/cloud-bootstrap-skills.py\" --project <pj名> --project-root \"$PJ_ROOT\" --hub-root \"$HUB_ROOT\" --runtimes claude" >&2
  echo "" >&2
  exit 0
fi

BOOTSTRAP_OUTPUT="$(python3 "$HUB_ROOT/scripts/cloud-bootstrap-skills.py" --project "$PROJECT_KEY" --project-root "$PJ_ROOT" --hub-root "$HUB_ROOT" --runtimes claude 2>&1)"
BOOTSTRAP_EXIT=$?

echo "" >&2
[ -n "$RESOLVE_WARN" ] && echo "  $RESOLVE_WARN" >&2
if [ "$BOOTSTRAP_EXIT" -ne 0 ]; then
  echo "⚠️  [cloud-hub-bootstrap] cloud-bootstrap-skills.py が失敗しました（project: $PROJECT_KEY）。" >&2
else
  echo "🔍 [cloud-hub-bootstrap] project: $PROJECT_KEY" >&2
fi
echo "$BOOTSTRAP_OUTPUT" >&2
echo "" >&2

# SessionStart hook は常に exit 0（ブロックしない、情報提供のみ）。
exit 0
