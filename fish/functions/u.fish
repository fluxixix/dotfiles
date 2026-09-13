function u --description "Update everything"
    set -g __u_failures 0

    # ── helpers ──────────────────────────────────────────────────────────────
    function _section
        set_color --bold cyan
        echo ""
        echo "══ $argv ══"
        set_color normal
    end

    function _ok
        set_color green; echo "  ✓ $argv"; set_color normal
    end

    function _fail
        set_color red; echo "  ✗ $argv"; set_color normal
    end

    function _skip
        set_color yellow; echo "  - $argv (not found, skipped)"; set_color normal
    end

    function _run --argument-names label
        set -e argv[1]
        $argv
        set -l status_code $status
        if test $status_code -eq 0
            _ok "$label"
        else
            _fail "$label (exit $status_code)"
            set -g __u_failures (math $__u_failures + 1)
        end
        return $status_code
    end

    # 网络类更新（如 ya pkg upgrade）失败后自动重试
    function _retry --argument-names max_attempts
        set -e argv[1]
        set -l attempt 1

        while true
            $argv
            set -l status_code $status
            if test $status_code -eq 0; or test $attempt -ge $max_attempts
                return $status_code
            end

            set_color yellow
            echo "  ↻ Retrying ($attempt/$max_attempts)"
            set_color normal
            sleep 2
            set attempt (math $attempt + 1)
        end
    end

    # ── Homebrew ──────────────────────────────────────────────────────────────
    _section "Homebrew"
    _run "Homebrew done" bash -lc "brew update && brew upgrade --no-ask && brew upgrade --cask --greedy --no-ask && brew autoremove && brew cleanup --prune=all"

    # ── Neovim (AstroNvim) ────────────────────────────────────────────────────
    _section "Neovim"
    if command -q nvim
        _run "Plugins synced" bash -lc "nvim --headless '+Lazy! sync' +qa 2>/dev/null"
        _run "AstroUpdate" bash -lc "nvim --headless '+AstroUpdate' +qa 2>/dev/null"
        _run "Mason packages updated" bash -lc "nvim --headless '+MasonToolsUpdate' +qa 2>/dev/null"
        _run "Treesitter updated" bash -lc "nvim --headless '+TSUpdateSync' +qa 2>/dev/null"
    else
        _skip "nvim"
    end

    # ── Go toolchain ──────────────────────────────────────────────────────────
    _section "Go"
    if command -q go
        set _gobin (go env GOPATH)/bin
        if test -d $_gobin
            for _bin in $_gobin/*
                set _pkg (go version -m $_bin 2>/dev/null | awk '$1=="path"{print $2; exit}')
                if test -n "$_pkg"
                    go install "$_pkg@latest" 2>/dev/null
                end
            end
            _ok "Go binaries updated"
        end
    else
        _skip "go"
    end

    # ── Rust ──────────────────────────────────────────────────────────────────
    _section "Rust"
    if command -q rustup
        rustup update
        if command -q cargo
            if test -x ~/.cargo/bin/cargo-install-update
                _run "cargo-update" cargo install-update -a
            else
                _skip "cargo-update (run: cargo install cargo-update)"
            end
            if test -x ~/.cargo/bin/cargo-cache
                _run "cargo-cache" cargo cache --autoclean
            else
                _skip "cargo-cache (run: cargo install cargo-cache)"
            end
        end
        _ok "Rust updated"
    else
        _skip "rustup"
    end

    # ── Node ──────────────────────────────────────────────────────────────────
    _section "Node"
    if command -q npm
        _run "npm updated" npm update -g
        npm cache clean --force
    else
        _skip "npm"
    end
    if command -q pnpm
        _run "pnpm updated" bash -lc "pnpm update -g && pnpm store prune"
    else
        _skip "pnpm"
    end

    # ── Python (uv) ───────────────────────────────────────────────────────────
    _section "Python / uv"
    if command -q uv
        _run "uv tools upgraded" uv tool upgrade --all
    else
        _skip "uv"
    end

    # ── Shell ─────────────────────────────────────────────────────────────────
    _section "Fish / Fisher"
    if functions -q fisher
        _run "Fisher plugins updated" fisher update
    else
        _skip "fisher"
    end

    _section "Tmux / TPM"
    # TPM 的并行更新器在插件失败时也可能返回成功，因此改为逐插件 git pull。
    set -l tpm_plugins (path filter -d ~/.config/tmux/plugins/*)
    if test (count $tpm_plugins) -gt 0
        for plugin in $tpm_plugins
            test -e "$plugin/.git"; or continue
            set -l name (path basename $plugin)
            set -lx GIT_TERMINAL_PROMPT 0
            _run "$name updated" git -C "$plugin" pull --ff-only
            and _run "$name submodules updated" git -C "$plugin" submodule update --init --recursive
        end
    else
        _skip "TPM (~/.config/tmux/plugins not found)"
    end

    # ── Tools ─────────────────────────────────────────────────────────────────
    _section "Yazi plugins"
    if command -q ya
        _run "Yazi plugins updated" _retry 3 ya pkg upgrade
    else
        _skip "ya"
    end

    # ── macOS App Store ───────────────────────────────────────────────────────
    _section "Mac App Store"
    if command -q mas
        _run "MAS updated" mas upgrade
    else
        _skip "mas"
    end

    # ── Mole ──────────────────────────────────────────────────────────────────
    _section "Mole"
    if command -q mo
        _run "Mole cleaned" bash -lc "printf '\\n' | mo clean"
        mo purge
    else
        _skip "mo (mole)"
    end

    # ── App caches ────────────────────────────────────────────────────────────
    _section "App Caches"
    _run "CleanShot media cleared" rm -rf ~/Library/Application\ Support/CleanShot/media

    # ── Done ──────────────────────────────────────────────────────────────────
    echo ""
    if test $__u_failures -eq 0
        set_color --bold green
        echo "✓ All updated"
    else
        set_color --bold red
        echo "✗ Update finished with $__u_failures failure(s)"
    end
    set_color normal

    functions --erase _section _ok _fail _skip _run _retry
    set -e __u_failures
end
