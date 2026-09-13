#!/bin/bash
# ──────────────────────────────────────────────────
# restore-sandbox-test.sh
#
# 目的：把 scripts/restore.sh 完整跑一遍并断言其行为，且
#       —— 不触碰真实 $HOME/.config
#       —— 不安装/卸载任何软件，不执行 sudo / chsh
#       —— 不访问网络
#
# 做法：
#   1. 造一个「假 HOME」($SANDBOX/home)，restore.sh 的所有落盘都发生在沙箱里。
#      注意 $HOME/.config/tmux 会被链到仓库的 tmux/ 目录，所以 TPM 那段
#      实际上会摸到仓库；靠下面的 bash 桩命令把它变成空操作。
#   2. 用 PATH 前置的「桩命令」拦下所有有副作用的命令（brew/git/cargo/sudo/
#      chsh/fish/curl/tee/bash）。桩只把调用记进日志，然后返回 0。
#   3. 被测脚本本身不做任何改动，可测试性完全由桩命令解决。
#
# 这是 CI 的冒烟测试层。
# ──────────────────────────────────────────────────
set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0

ok() { echo -e "  ${GREEN}[✓]${NC} $*"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}[✗]${NC} $*"; FAIL=$((FAIL + 1)); }
# detail 只打印明细，不计入断言计数（供 check_links 这类逐项校验使用）
detail() { echo -e "      ${RED}[✗]${NC} $*"; }
section() { echo -e "\n${YELLOW}── $* ──${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESTORE="$DOTFILES_DIR/scripts/restore.sh"

# 与 restore.sh 第 100 行的清单保持一致（14 项）
LINK_DIRS=(aerospace bat btop eza fish ghostty git go-musicfox lazygit npm nvim starship tmux yazi)
# 用于「拒绝覆盖」用例：除 yazi 外的 13 项
OTHER_DIRS=()
for _d in "${LINK_DIRS[@]}"; do
	if [[ "$_d" == "yazi" ]]; then
		continue
	fi
	OTHER_DIRS+=("$_d")
done

if [[ ! -x "$RESTORE" ]]; then
	echo -e "${RED}[✗]${NC} 被测脚本不存在或不可执行：$RESTORE" >&2
	exit 1
fi

# 断言 7 的基线：记录运行前的仓库状态（此时测试脚本自身可能是 untracked，
# 属于预期噪音，所以断言 7 采用「前后对比」而不是「必须为空」）
GIT_STATUS_BEFORE="$(git -C "$DOTFILES_DIR" status --porcelain)"

# ──────────────────────────────────────────────────
# 沙箱
# ──────────────────────────────────────────────────
SANDBOX="$(mktemp -d)"
SB_HOME="$SANDBOX/home"
STUB_BIN="$SANDBOX/bin"
STUB_LOG="$SANDBOX/calls.log"

mkdir -p "$SB_HOME" "$STUB_BIN"
: > "$STUB_LOG"

cleanup() {
	if [[ "$FAIL" -gt 0 ]]; then
		echo -e "\n${YELLOW}[!] 有断言失败，保留沙箱便于排查：$SANDBOX${NC}"
		echo -e "${YELLOW}── 桩命令调用日志 $STUB_LOG ──${NC}"
		cat "$STUB_LOG" || true
	else
		rm -rf "$SANDBOX" || true
	fi
}
trap cleanup EXIT

echo "沙箱目录：$SANDBOX"
echo "假 HOME ：$SB_HOME"

# 生成桩命令：把 "$0 $*"（含参数）追加到调用日志，然后返回 0。
# 日志路径必须硬写进桩内容里 —— 桩是独立子进程，拿不到父 shell 的变量。
make_stub() {
	local name="$1"
	local body="${2:-}"
	{
		echo '#!/bin/bash'
		echo "printf '%s\\n' \"\$0 \$*\" >> \"$STUB_LOG\""
		if [[ -n "$body" ]]; then
			echo "$body"
		fi
		echo 'exit 0'
	} >"$STUB_BIN/$name"
	chmod +x "$STUB_BIN/$name"
}

# brew：shellenv 要输出可 eval 的内容；bundle 等只记录
make_stub brew 'case "${1:-}" in
shellenv)
	echo "export HOMEBREW_PREFIX=/opt/homebrew"
	;;
esac'

# git：只记录，绝不真的 clone，也不写任何文件
make_stub git ''

# cargo：install --list 报出「已安装」，让 restore.sh 走跳过分支，绝不真的安装
make_stub cargo 'if [[ "${1:-}" == "install" && "${2:-}" == "--list" ]]; then
	echo "cargo-cache v0.8.0:"
	echo "cargo-update v16.0.0:"
fi'

# fish：恒返回 0 —— functions -q fisher 判为「已存在」，
#       于是跳过 curl 网络下载；fisher update 也只是被记录
make_stub fish ''

# 只记录、只返回 0 的「危险命令」桩
make_stub sudo ''
make_stub chsh ''
make_stub curl ''
make_stub tee ''

# bash 桩是必须的：restore.sh 会执行 bash "$TPM_DIR/bin/install_plugins"，
# 而 $TPM_DIR 真实落在仓库的 tmux/ 目录里（因为 $HOME/.config/tmux 是指向
# 仓库的软链接）。不拦住就会真的去安装 tmux 插件、往仓库里写文件。
# 桩 bash 让这一步变成空操作。
make_stub bash ''

# ──────────────────────────────────────────────────
# 执行辅助
# ──────────────────────────────────────────────────

# 在指定的假 HOME 里执行被测脚本。
# 关键：必须以「可执行文件」方式调用（而不是 bash "$RESTORE"），
#       否则会被上面的 bash 桩拦掉。
# 同样关键：PATH 只对这一个子进程生效，不在测试脚本自身 export，
#       避免测试脚本自己用的 bash/git 被桩掉。
LAST_RC=0
run_restore() {
	local home="$1" log="$2"
	LAST_RC=0
	HOME="$home" PATH="$STUB_BIN:$PATH" "$RESTORE" >"$log" 2>&1 || LAST_RC=$?
}

# 新建一个干净沙箱（HOME 目录），返回其路径
new_sandbox_home() {
	local d
	d="$(mktemp -d "$SANDBOX/run.XXXXXX")"
	mkdir -p "$d/home"
	echo "$d/home"
}

# 在全新的干净沙箱里执行 restore.sh
#   $1 = 假 HOME 目录，留空则新建一个（用于「另一个干净沙箱」）
#   $2 = none       ：完全干净的 HOME
#        block-yazi ：预置真实目录 ~/.config/yazi（含哨兵文件），验证「拒绝覆盖」
# 结果：SB_HOME_LAST / SB_LOG_LAST / LAST_RC
SB_HOME_LAST=""
SB_LOG_LAST=""
run_restore_in_fresh_sandbox() {
	local home="${1:-}" preset="${2:-none}"
	if [[ -z "$home" ]]; then
		home="$(new_sandbox_home)"
	fi
	SB_HOME_LAST="$home"
	SB_LOG_LAST="$(dirname "$SB_HOME_LAST")/restore.log"
	if [[ "$preset" == "block-yazi" ]]; then
		mkdir -p "$SB_HOME_LAST/.config/yazi"
		: >"$SB_HOME_LAST/.config/yazi/sentinel.txt"
	fi
	run_restore "$SB_HOME_LAST" "$SB_LOG_LAST"
}

# 链接集合快照，形如：
#   nvim -> /Users/chao/dotfiles/nvim
link_snapshot() {
	local home="$1" l
	find "$home/.config" -maxdepth 1 -type l -print 2>/dev/null | sort | while read -r l; do
		echo "$(basename "$l") -> $(readlink "$l")"
	done
}

# 校验给定目录名都必须是「指向仓库的软链接」且目标存在
check_links() {
	local home="$1"
	shift
	local n dst want actual ret=0
	for n in "$@"; do
		dst="$home/.config/$n"
		want="$DOTFILES_DIR/$n"
		if [[ ! -L "$dst" ]]; then
			detail "$dst 不是软链接（期望 → ${want}）"
			ret=1
			continue
		fi
		actual="$(readlink "$dst")"
		if [[ "$actual" != "$want" ]]; then
			detail "$dst → ${actual}（期望 ${want}）"
			ret=1
			continue
		fi
		if [[ ! -e "$dst" ]]; then
			detail "$dst → ${actual} 指向的目标不存在"
			ret=1
		fi
	done
	return "$ret"
}

# ──────────────────────────────────────────────────
# 第 1 轮：干净沙箱执行
# ──────────────────────────────────────────────────
section "第 1 轮：干净沙箱执行 restore.sh"
run_restore_in_fresh_sandbox "$SB_HOME" none
SB1_HOME="$SB_HOME_LAST"
SB1_LOG="$SB_LOG_LAST"
SB1_RC="$LAST_RC"

if [[ "$SB1_RC" -eq 0 ]]; then
	ok "断言 1：restore.sh 退出码 = 0"
else
	bad "断言 1：restore.sh 退出码（期望 0，实际 ${SB1_RC}）"
	echo "── restore.sh 输出（${SB1_LOG}）──"
	cat "$SB1_LOG" || true
fi

section "断言 2：配置目录软链接正确"
if check_links "$SB1_HOME" "${LINK_DIRS[@]}"; then
	ok "断言 2：${#LINK_DIRS[@]} 个配置目录均为指向仓库的软链接且目标存在"
else
	bad "断言 2：存在未正确建立的软链接（期望 ${#LINK_DIRS[@]} 个目录全部指向仓库，详见上方明细）"
fi

section "断言 3：没有失效（悬空）软链接"
dangling="$(find "$SB1_HOME/.config" -type l ! -exec test -e {} \; -print 2>/dev/null || true)"
if [[ -z "$dangling" ]]; then
	ok "断言 3：\$SB_HOME/.config 下不存在指向不存在目标的软链接"
else
	bad "断言 3：发现失效软链接（期望无，实际如下）"
	echo "$dangling"
fi

# ──────────────────────────────────────────────────
# 断言 4：幂等
# ──────────────────────────────────────────────────
section "断言 4：幂等（同一沙箱再执行一次）"
SNAP1="$(link_snapshot "$SB1_HOME")"
run_restore "$SB1_HOME" "$SANDBOX/run2.log"
SNAP2="$(link_snapshot "$SB1_HOME")"
if [[ "$LAST_RC" -ne 0 ]]; then
	bad "断言 4：第二次执行退出码（期望 0，实际 ${LAST_RC}）"
	echo "── 第二次 restore.sh 输出 ──"
	cat "$SANDBOX/run2.log" || true
elif [[ "$SNAP1" == "$SNAP2" ]]; then
	ok "断言 4：第二次执行仍退出 0，两次链接集合一致（$(printf '%s\n' "$SNAP1" | wc -l | tr -d ' ') 项）"
else
	bad "断言 4：两次链接集合不一致"
	echo "── 第一次链接集合 ──"
	echo "$SNAP1"
	echo "── 第二次链接集合 ──"
	echo "$SNAP2"
fi

# ──────────────────────────────────────────────────
# 断言 5：拒绝覆盖真实目录
# ──────────────────────────────────────────────────
section "断言 5：拒绝覆盖真实目录（另一个干净沙箱，预置 .config/yazi）"
run_restore_in_fresh_sandbox "" block-yazi
SB2_HOME="$SB_HOME_LAST"
SB2_LOG="$SB_LOG_LAST"
SB2_RC="$LAST_RC"

if [[ "$SB2_RC" -eq 0 ]]; then
	ok "断言 5-①：仍有真实目录时 restore.sh 退出码 = 0"
else
	bad "断言 5-①：退出码（期望 0，实际 ${SB2_RC}）"
	echo "── restore.sh 输出（${SB2_LOG}）──"
	cat "$SB2_LOG" || true
fi

if [[ -f "$SB2_HOME/.config/yazi/sentinel.txt" ]]; then
	ok "断言 5-②：哨兵文件 $SB2_HOME/.config/yazi/sentinel.txt 仍在"
else
	bad "断言 5-②：哨兵文件被破坏（期望存在，实际不存在）"
fi

if [[ -d "$SB2_HOME/.config/yazi" && ! -L "$SB2_HOME/.config/yazi" ]]; then
	ok "断言 5-③：.config/yazi 仍是真实目录（不是软链接）"
else
	bad "断言 5-③：.config/yazi 状态不对（期望真实目录且非软链接，实际：$(ls -ld "$SB2_HOME/.config/yazi" 2>&1 || true)）"
fi

if check_links "$SB2_HOME" "${OTHER_DIRS[@]}"; then
	ok "断言 5-④：其余 ${#OTHER_DIRS[@]} 个目录的软链接照常建立"
else
	bad "断言 5-④：其余目录的软链接未照常建立（期望 ${#OTHER_DIRS[@]} 个，详见上方明细）"
fi

# ──────────────────────────────────────────────────
# 断言 6：安全性（无变更性包操作）
# ──────────────────────────────────────────────────
section "断言 6：安全性（桩日志里不得出现变更性包操作）"
FORBIDDEN_RE='(brew (install|upgrade|uninstall|reinstall)([[:space:]]|$))|(cargo (uninstall|upgrade|reinstall)([[:space:]]|$))|(cargo install [^-])'
violations="$(grep -E "$FORBIDDEN_RE" "$STUB_LOG" || true)"
if [[ -z "$violations" ]]; then
	ok "断言 6：未出现 brew install/upgrade/uninstall/reinstall 或 cargo install <pkg>/uninstall/upgrade/reinstall"
else
	bad "断言 6：发现变更性包操作（期望无，实际命中如下）"
	echo "$violations"
fi

# ──────────────────────────────────────────────────
# 断言 7：不污染仓库工作区
# ──────────────────────────────────────────────────
section "断言 7：仓库工作区未被污染"
GIT_STATUS_AFTER="$(git -C "$DOTFILES_DIR" status --porcelain)"
if [[ "$GIT_STATUS_AFTER" == "$GIT_STATUS_BEFORE" ]]; then
	ok "断言 7：git status 与运行前完全一致"
	if [[ -n "$GIT_STATUS_BEFORE" ]]; then
		echo "  （运行前后均存在的既有改动，非本次测试产生：）"
		echo "$GIT_STATUS_BEFORE" | sed 's/^/    /'
	fi
else
	bad "断言 7：git status 发生变化（期望一致，实际不同）"
	echo "── 运行前 ──"
	echo "$GIT_STATUS_BEFORE"
	echo "── 运行后 ──"
	echo "$GIT_STATUS_AFTER"
fi

# ──────────────────────────────────────────────────
# 桩命令调用记录（证据）
# ──────────────────────────────────────────────────
section "桩命令调用记录"
cat "$STUB_LOG" || true

# ──────────────────────────────────────────────────
# 汇总
# ──────────────────────────────────────────────────
section "汇总"
echo -e "通过：${GREEN}${PASS}${NC}    失败：${RED}${FAIL}${NC}"
if [[ "$FAIL" -gt 0 ]]; then
	echo -e "${RED}[✗] 沙箱冒烟测试失败${NC}"
	exit 1
fi
echo -e "${GREEN}[✓] 沙箱冒烟测试全部通过${NC}"
