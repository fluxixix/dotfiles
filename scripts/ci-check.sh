#!/bin/bash

# ──────────────────────────────────────────────────
# ci-check.sh — 静态检查 + 仓库一致性检查
# 本地与 GitHub Actions CI 共用同一份逻辑。
#
# 用法: bash scripts/ci-check.sh [--static|--consistency|--report|--all]
# 无参数等价于 --all；任一检查失败都会让脚本以非零码退出。
# ──────────────────────────────────────────────────

set -Eeuo pipefail

# ──────────────────────────────────────────────────
# Colors & logging
# ──────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FAILURES=0
PASSES=0

pass() { echo -e "${GREEN}[✓]${NC} $*"; PASSES=$((PASSES + 1)); }
note() { echo -e "${YELLOW}[!]${NC} $*"; }
section() { echo -e "\n${YELLOW}── $* ──${NC}"; }
fail() {
	echo -e "${RED}[✗]${NC} $*" >&2
	FAILURES=$((FAILURES + 1))
}

# ──────────────────────────────────────────────────
# 常量
# ──────────────────────────────────────────────────
# 根目录下这些目录不是「一个工具一个配置目录」约定里的工具配置目录，
# 因此不参与「实物 → 清单」的一致性检查：
#   .git     版本库元数据
#   .github  CI 配置
#   scripts  仓库自身的维护脚本
# 另外，被 .gitignore 忽略的目录（.trae、.qoder、.claude 这类本地工具目录）
# 会自动跳过，无需在此登记。
NON_TOOL_DIRS=(.git .github scripts)

RUN_STATIC=0
RUN_CONSISTENCY=0
RUN_REPORT=0

usage() {
	cat <<'EOF'
用法: bash scripts/ci-check.sh [选项]

选项:
  --static        只跑静态检查（bash -n / shellcheck / ruby -c / fish -n）
  --consistency   只跑仓库一致性检查（清单、README、tracked/ignored、Brewfile tap）
  --report        只跑仅报告不阻断的项（.gitignore 失效规则、失效软链接）
  --all           跑全部检查（默认，无参数时等价于此）
  -h, --help      显示本帮助
EOF
}

# ──────────────────────────────────────────────────
# 参数解析
# ──────────────────────────────────────────────────
if [[ $# -eq 0 ]]; then
	RUN_STATIC=1
	RUN_CONSISTENCY=1
	RUN_REPORT=1
fi
while [[ $# -gt 0 ]]; do
	case "$1" in
		--static) RUN_STATIC=1 ;;
		--consistency) RUN_CONSISTENCY=1 ;;
		--report) RUN_REPORT=1 ;;
		--all)
			RUN_STATIC=1
			RUN_CONSISTENCY=1
			RUN_REPORT=1
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "未知参数: $1" >&2
			usage >&2
			exit 2
			;;
	esac
	shift
done

# ──────────────────────────────────────────────────
# 第一部分：静态检查
# ──────────────────────────────────────────────────
run_static() {
	section "静态检查（--static）"

	# 检查对象动态推导，不写死文件名；用 NUL 分隔以兼容含空格与中文的路径。
	# 工作区里已删除但尚未提交的文件仍会被 git ls-files 列出，跳过它们，
	# 否则会把「文件不存在」误报成语法错误。
	local -a sh_files=()
	while IFS= read -r -d '' f; do
		[[ -f "$DOTFILES_DIR/$f" ]] || continue
		sh_files+=("$f")
	done < <(git -C "$DOTFILES_DIR" ls-files -z '*.sh')

	local -a fish_files=()
	while IFS= read -r -d '' f; do
		[[ -f "$DOTFILES_DIR/$f" ]] || continue
		fish_files+=("$f")
	done < <(git -C "$DOTFILES_DIR" ls-files -z '*.fish' 'fish/themes/*.theme')

	local f out

	# 1. bash -n：所有被跟踪的 shell 脚本语法检查
	for f in "${sh_files[@]}"; do
		if out="$(bash -n "$DOTFILES_DIR/$f" 2>&1)"; then
			pass "bash -n $f"
		else
			fail "bash -n 语法错误: $f"
			printf '%s\n' "$out" | sed 's/^/    /' >&2
		fi
	done

	# 2. shellcheck：error 级阻断
	if ! command -v shellcheck >/dev/null 2>&1; then
		fail "shellcheck 未安装，无法执行 shellcheck 检查（请先安装: brew install shellcheck）"
	else
		for f in "${sh_files[@]}"; do
			if out="$(shellcheck --severity=error --format=gcc "$DOTFILES_DIR/$f" 2>&1)"; then
				pass "shellcheck (error) $f"
			else
				fail "shellcheck (error) $f"
				printf '%s\n' "$out" | sed 's/^/    /' >&2
			fi
		done

		# 2b. shellcheck：warning 级仅打印不阻断
		section "shellcheck warnings（不阻断）"
		for f in "${sh_files[@]}"; do
			# grep 无匹配时返回 1，用 || true 容忍；放在命令替换里不影响 set -e
			out="$(shellcheck --severity=warning --format=gcc "$DOTFILES_DIR/$f" 2>&1 | grep 'warning:' || true)"
			if [[ -n "$out" ]]; then
				printf '%s\n' "$out" | sed 's/^/    /'
			fi
		done
	fi

	# 3. ruby -c：Brewfile 的 Ruby 语法
	if ! command -v ruby >/dev/null 2>&1; then
		fail "ruby 未安装，无法检查 Brewfile 语法"
	else
		if out="$(ruby -c "$DOTFILES_DIR/Brewfile" 2>&1)"; then
			pass "ruby -c Brewfile"
		else
			fail "ruby -c Brewfile 语法错误"
			printf '%s\n' "$out" | sed 's/^/    /' >&2
		fi
	fi

	# 4. fish -n：所有被跟踪的 fish 文件与主题文件
	if ! command -v fish >/dev/null 2>&1; then
		fail "fish 未安装，无法检查 fish 文件语法"
	else
		for f in "${fish_files[@]}"; do
			if out="$(fish -n "$DOTFILES_DIR/$f" 2>&1)"; then
				pass "fish -n $f"
			else
				fail "fish -n 语法错误: $f"
				printf '%s\n' "$out" | sed 's/^/    /' >&2
			fi
		done
	fi
}

# ──────────────────────────────────────────────────
# 第二部分：仓库一致性检查
# ──────────────────────────────────────────────────
run_consistency() {
	section "仓库一致性检查（--consistency）"

	local MANIFEST=()
	local name base d line tl tap hit i

	# 从 restore.sh 解析部署清单，供后续复用
	local manifest_line manifest_inner
	manifest_line="$(grep -E '^for dir in ' "$DOTFILES_DIR/scripts/restore.sh" | head -1 || true)"
	if [[ -z "$manifest_line" ]]; then
		fail "无法从 scripts/restore.sh 解析部署清单（未找到 'for dir in ...' 行），restore.sh 结构可能已被改动"
		return
	fi
	manifest_inner="${manifest_line#*in }"
	manifest_inner="${manifest_inner%%;*}"
	read -r -a MANIFEST <<<"$manifest_inner"
	if [[ ${#MANIFEST[@]} -eq 0 ]]; then
		fail "从 scripts/restore.sh 解析出的部署清单为空，restore.sh 结构可能已被改动"
		return
	fi
	pass "解析 restore.sh 部署清单（共 ${#MANIFEST[@]} 项）: ${MANIFEST[*]}"

	# 1. 清单 → 实物：清单里每个名字必须存在且是目录
	local missing=0
	for name in "${MANIFEST[@]}"; do
		if [[ ! -d "$DOTFILES_DIR/$name" ]]; then
			fail "清单中的目录不存在或不是目录: ${name}（期望 ${DOTFILES_DIR}/${name} 为目录）"
			missing=1
		fi
	done
	if [[ "$missing" -eq 0 ]]; then
		pass "清单中 ${#MANIFEST[@]} 个目录均存在于仓库根目录"
	fi

	# 2. 实物 → 清单：根目录下的目录必须纳入清单或白名单
	local unexpected=0
	while IFS= read -r d; do
		base="$(basename "$d")"
		# 被 .gitignore 忽略的目录（本地 IDE / 工具产物）不参与该检查
		if git -C "$DOTFILES_DIR" check-ignore -q "$d"; then
			continue
		fi
		hit=0
		for name in "${MANIFEST[@]}"; do
			if [[ "$base" == "$name" ]]; then
				hit=1
				break
			fi
		done
		for name in "${NON_TOOL_DIRS[@]}"; do
			if [[ "$base" == "$name" ]]; then
				hit=1
				break
			fi
		done
		if [[ "$hit" -eq 0 ]]; then
			fail "根目录下的目录既不在 restore.sh 清单内、也不在白名单内: $base"
			unexpected=1
		fi
	done < <(find "$DOTFILES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
	if [[ "$unexpected" -eq 0 ]]; then
		pass "根目录下所有目录均已纳入清单或白名单"
	fi

	# 3a. 文档 → 清单：README fish 代码块中的目录列表需与脚本清单逐项逐序一致
	local -a README_LIST=()
	local readme_line readme_inner
	readme_line="$(grep -E '^for dir in ' "$DOTFILES_DIR/README.md" | head -1 || true)"
	if [[ -z "$readme_line" ]]; then
		fail "无法从 README.md 解析 fish 目录清单（未找到 'for dir in ...' 行）"
	else
		readme_inner="${readme_line#*in }"
		readme_inner="${readme_inner%%;*}"
		read -r -a README_LIST <<<"$readme_inner"

		local mismatch=0
		if [[ ${#README_LIST[@]} -ne ${#MANIFEST[@]} ]]; then
			fail "README 目录清单数量与 restore.sh 不一致（脚本 ${#MANIFEST[@]} 项 / README ${#README_LIST[@]} 项）"
			mismatch=1
		fi
		for ((i = 0; i < ${#MANIFEST[@]} && i < ${#README_LIST[@]}; i++)); do
			if [[ "${MANIFEST[$i]}" != "${README_LIST[$i]}" ]]; then
				fail "README 目录清单第 $((i + 1)) 项与脚本不一致: 脚本='${MANIFEST[$i]}' README='${README_LIST[$i]}'"
				mismatch=1
			fi
		done
		for ((i = ${#README_LIST[@]}; i < ${#MANIFEST[@]}; i++)); do
			fail "README 目录清单缺少第 $((i + 1)) 项: 脚本='${MANIFEST[$i]}' README=(无)"
			mismatch=1
		done
		for ((i = ${#MANIFEST[@]}; i < ${#README_LIST[@]}; i++)); do
			fail "README 目录清单多出第 $((i + 1)) 项: 脚本=(无) README='${README_LIST[$i]}'"
			mismatch=1
		done
		if [[ "$mismatch" -eq 0 ]]; then
			pass "README 目录清单与 restore.sh 一致（顺序、数量、每个名字均相同）"
		else
			echo "    脚本清单:   ${MANIFEST[*]}" >&2
			echo "    README清单: ${README_LIST[*]}" >&2
		fi
	fi

	# 3b. 文档 → 清单：README 中「软链接 N 个配置目录」的计数需与清单长度一致
	local count_str count_num
	count_str="$(grep -oE '软链接 [0-9]+ 个配置目录' "$DOTFILES_DIR/README.md" | head -1 || true)"
	if [[ -z "$count_str" ]]; then
		fail "README 中未找到「软链接 N 个配置目录」的计数描述"
	else
		count_num="${count_str#软链接 }"
		count_num="${count_num%% *}"
		if [[ "$count_num" -eq ${#MANIFEST[@]} ]]; then
			pass "README 计数描述与清单长度一致（软链接 $count_num 个配置目录）"
		else
			fail "README 计数描述与清单长度不一致: 期望 ${#MANIFEST[@]} 个，实际 $count_num 个"
		fi
	fi

	# 4. 跟踪与忽略不冲突：不能有文件同时被跟踪又被忽略
	local ignored
	ignored="$(git -C "$DOTFILES_DIR" ls-files -i -c --exclude-standard || true)"
	if [[ -z "$ignored" ]]; then
		pass "跟踪与忽略不冲突（无文件同时被跟踪又被忽略）"
	else
		fail "存在同时被跟踪又被忽略的文件:"
		printf '%s\n' "$ignored" | sed 's/^/    /' >&2
	fi

	# 5. Brewfile 的 tap 无死条目：每个 tap 都必须被 brew/cask 引用
	while IFS= read -r tap; do
		if [[ -z "$tap" ]]; then
			continue
		fi
		hit=0
		while IFS= read -r line; do
			if [[ "$line" == "brew \"$tap/"* || "$line" == "cask \"$tap/"* ]]; then
				hit=1
				break
			fi
		done < <(grep -E '^(brew|cask) "' "$DOTFILES_DIR/Brewfile" || true)
		if [[ "$hit" -eq 1 ]]; then
			pass "Brewfile tap 有引用: $tap"
		else
			fail "Brewfile 中的 tap 无任何 brew/cask 引用（死条目）: $tap"
		fi
	done < <(grep -oE '^tap "[^"]+"' "$DOTFILES_DIR/Brewfile" | sed -E 's/^tap "//; s/"$//' || true)

	# 6. tap 已声明信任：所有 tap 行都必须带 trusted: true
	while IFS= read -r tl; do
		if [[ "$tl" == *'trusted: true'* ]]; then
			pass "Brewfile tap 已声明信任: $tl"
		else
			fail "Brewfile tap 缺少 trusted: true: $tl"
		fi
	done < <(grep -E '^tap ' "$DOTFILES_DIR/Brewfile" || true)
}

# ──────────────────────────────────────────────────
# 第三部分：仅报告不阻断
# ──────────────────────────────────────────────────
run_report() {
	section "仅报告不阻断（--report）"

	local rule dirpart l
	local dangling=0

	# 1. .gitignore 中指向不存在目录的规则（为将来保留的规则属正常现象）
	#    判定方式：取规则里的「目录部分」——无通配符的规则取其父目录，
	#    有通配符的规则取通配符之前的目录；该目录不存在才提示。
	#    只匹配文件名的规则（如 .DS_Store）没有目录部分，跳过不报，避免噪音。
	while IFS= read -r rule; do
		if [[ -z "$rule" ]]; then
			continue
		fi
		if [[ "$rule" == '#'* ]]; then
			continue
		fi
		if [[ "$rule" == '!'* ]]; then
			continue
		fi
		rule="${rule%/}"
		if [[ "$rule" != */* ]]; then
			continue
		fi
		dirpart="${rule%/*}"
		if [[ "$dirpart" == *'*'* || "$dirpart" == *'?'* ]]; then
			continue
		fi
		if [[ ! -e "$DOTFILES_DIR/$dirpart" ]]; then
			note ".gitignore 规则所属目录不存在: ${rule}（目录: ${dirpart}）"
		fi
	done <"$DOTFILES_DIR/.gitignore"

	# 2. 仓库内指向不存在目标的软链接（排除 .git）
	while IFS= read -r l; do
		if [[ -z "$l" ]]; then
			continue
		fi
		note "失效软链接: ${l#"$DOTFILES_DIR"/} → $(readlink "$l" || true)"
		dangling=1
	done < <(find "$DOTFILES_DIR" -path "$DOTFILES_DIR/.git" -prune -o -type l ! -exec test -e {} \; -print 2>/dev/null)
	if [[ "$dangling" -eq 0 ]]; then
		pass "仓库内未发现失效软链接"
	fi
}

# ──────────────────────────────────────────────────
# 执行 & 汇总
# ──────────────────────────────────────────────────
if [[ "$RUN_STATIC" -eq 1 ]]; then
	run_static
fi
if [[ "$RUN_CONSISTENCY" -eq 1 ]]; then
	run_consistency
fi
if [[ "$RUN_REPORT" -eq 1 ]]; then
	run_report
fi

section "汇总"
if [[ "$FAILURES" -eq 0 ]]; then
	echo -e "${GREEN}${PASSES} 项通过 / 0 项失败${NC}"
	exit 0
else
	echo -e "${RED}${PASSES} 项通过 / ${FAILURES} 项失败${NC}" >&2
	exit 1
fi
