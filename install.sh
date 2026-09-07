#!/bin/sh
#
# dotfiles インストーラー (POSIX sh互換)
# dotfilesのシンボリックリンクをホームディレクトリに作成します
#
# 使い方:
#   ./install.sh              # 対話モード(デフォルト)
#   ./install.sh -f           # 全ファイルを強制インストール
#   ./install.sh -n           # ドライラン(プレビューのみ)
#   ./install.sh -u           # アンインストール
#

set -eu

# 一時ファイル cleanup
_TMPFILES=""
cleanup_tmpfiles() {
    for _f in $_TMPFILES; do
        rm -f "$_f"
    done
}
trap cleanup_tmpfiles EXIT INT TERM

# ============================================================================
# 定数・設定
# ============================================================================

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"

MODE_INTERACTIVE=true
MODE_DRY_RUN=false
MODE_UNINSTALL=false

COUNT_CREATED=0
COUNT_SKIPPED=0
COUNT_BACKUP=0
COUNT_REMOVED=0
COUNT_ERROR=0

SHELL_SELECTED=false
SHELL_TYPE=""
SHELL_COMPONENTS=""
GIT_SELECTED=false
VIM_SELECTED=false
BIN_SELECTED=false
CLAUDE_SELECTED=false
CODEX_SELECTED=false
GITCONFIG_VARIANT=""

UNINSTALL_SHELL=false
UNINSTALL_GIT=false
UNINSTALL_VIM=false
UNINSTALL_BIN=false
UNINSTALL_CLAUDE=false
UNINSTALL_CODEX=false

VENDOR_SKILLS="composition-patterns react-best-practices web-design-guidelines"
COMMON_HOOKS="common/hooks"
COMMON_QA_NIGHTMARE_CHECKLISTS="common/qa-nightmare/checklists"
COMMON_QA_NIGHTMARE_MANIFEST="common/qa-nightmare/manifest.json"
COMMON_COMMANDS="common/commands"
COMMON_RULES="common/rules"
COMMON_SKILLS="common/skills"
AI_ASSET_GENERATOR_REL="scripts/generate-ai-assets.py"
AI_ASSET_ROOT_REL=".generated/ai-assets"
AI_CLAUDE_ASSETS=".generated/ai-assets/claude"
AI_CODEX_ASSETS=".generated/ai-assets/codex"
AI_PLUGIN_ASSETS=".generated/ai-assets/plugins"

DOTWORK_MARKER_BEGIN="# === dotfile-work: BEGIN ==="
DOTWORK_MARKER_END="# === dotfile-work: END ==="

# ============================================================================
# カラー出力
# ============================================================================

if [ -t 1 ]; then
    COLOR_GREEN=$(printf '\033[0;32m')
    COLOR_YELLOW=$(printf '\033[0;33m')
    COLOR_RED=$(printf '\033[0;31m')
    COLOR_BLUE=$(printf '\033[0;34m')
    COLOR_CYAN=$(printf '\033[0;36m')
    COLOR_BOLD=$(printf '\033[1m')
    COLOR_RESET=$(printf '\033[0m')
else
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_RED=''
    COLOR_BLUE=''
    COLOR_CYAN=''
    COLOR_BOLD=''
    COLOR_RESET=''
fi

# ============================================================================
# ユーティリティ
# ============================================================================

canonicalize_path() {
    [ -z "$1" ] && return 0
    readlink -f "$1" 2>/dev/null || realpath "$1" 2>/dev/null || {
        _cp_dir=$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P) || { echo "$1"; return; }
        echo "${_cp_dir}/$(basename "$1")"
    }
}

# global_ プレフィックスを除去
strip_global_prefix() {
    case "$1" in
        global_*) printf '%s\n' "${1#global_}" ;;
        *)        printf '%s\n' "$1" ;;
    esac
}

claude_target_relative() {
    case "$1" in
        statusline.settings.json) printf '%s\n' "statusline.json" ;;
        *)                        strip_global_prefix "$1" ;;
    esac
}

die() {
    printf "${COLOR_RED}エラー:${COLOR_RESET} %s\n" "$1" >&2
    exit "${2:-1}"
}

print_success() { printf "${COLOR_GREEN}✓${COLOR_RESET} %s\n" "$1"; }
print_skip()    { printf "${COLOR_YELLOW}○${COLOR_RESET} %s\n" "$1"; }
print_error()   { printf "${COLOR_RED}✗${COLOR_RESET} %s\n" "$1"; }
print_info()    { printf "${COLOR_BLUE}→${COLOR_RESET} %s\n" "$1"; }
print_header()  { printf "\n${COLOR_BOLD}${COLOR_CYAN}%s${COLOR_RESET}\n" "$1"; }

check_requirements() {
    for cmd in git python3 ln mkdir rm mv cp cmp; do
        command -v "$cmd" >/dev/null 2>&1 || die "必須コマンドが見つかりません: $cmd"
    done
}

ensure_dir() {
    _dir="$1"

    if [ -L "$_dir" ]; then
        if [ "$MODE_DRY_RUN" = "true" ]; then
            print_info "[ドライラン] 既存リンク削除: $_dir"
        else
            rm "$_dir" 2>/dev/null || true
        fi
    fi

    [ -d "$_dir" ] && return 0

    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] ディレクトリ作成: $_dir"
        return 0
    fi

    if ! mkdir -p "$_dir" 2>/dev/null; then
        print_error "ディレクトリ作成失敗: $_dir"
        COUNT_ERROR=$((COUNT_ERROR + 1))
        return 1
    fi
    return 0
}

absolute_path_without_following_leaf() {
    _path="$1"
    _base="$2"

    case "$_path" in
        /*) _abs_path="$_path" ;;
        *)  _abs_path="${_base}/$_path" ;;
    esac

    _abs_dir=$(cd -P "$(dirname "$_abs_path")" 2>/dev/null && pwd -P) || {
        printf '%s\n' "$_abs_path"
        return 0
    }
    printf '%s/%s\n' "$_abs_dir" "$(basename "$_abs_path")"
}

link_points_to_repo_entry() {
    _link="$1"
    _repo_entry="$2"

    [ -L "$_link" ] || return 1
    _link_target=$(readlink "$_link" 2>/dev/null) || return 1
    _link_target=$(absolute_path_without_following_leaf "$_link_target" "$(dirname "$_link")")
    _expected_target=$(absolute_path_without_following_leaf "$_repo_entry" "$DOTFILES_DIR")
    [ "$_link_target" = "$_expected_target" ]
}

next_backup_path() {
    _target="$1"
    _backup="${_target}.bak"

    if [ ! -e "$_backup" ] && [ ! -L "$_backup" ]; then
        printf '%s\n' "$_backup"
        return 0
    fi

    _index=1
    while :; do
        _backup="${_target}.bak.${_index}"
        if [ ! -e "$_backup" ] && [ ! -L "$_backup" ]; then
            printf '%s\n' "$_backup"
            return 0
        fi
        _index=$((_index + 1))
    done
}

prepare_stow_target() {
    _dest="$1"
    _package="$2"
    _stow_entry="$3"

    [ -e "$_dest" ] || [ -L "$_dest" ] || return 0
    link_points_to_repo_entry "$_dest" "$_stow_entry" && return 0

    if [ "$MODE_DRY_RUN" = "true" ]; then
        if [ -L "$_dest" ]; then
            print_info "[ドライラン] 既存リンク削除: $_dest"
        else
            _backup=$(next_backup_path "$_dest")
            print_info "[ドライラン] バックアップ: $_dest -> $_backup"
            COUNT_BACKUP=$((COUNT_BACKUP + 1))
        fi
        print_info "[ドライラン] stow package 作成: $_package"
        COUNT_CREATED=$((COUNT_CREATED + 1))
        return 2
    fi

    if [ -L "$_dest" ]; then
        if rm "$_dest" 2>/dev/null; then
            print_info "既存リンク削除: $_dest"
        else
            print_error "既存リンク削除失敗: $_dest"
            COUNT_ERROR=$((COUNT_ERROR + 1))
            return 1
        fi
    elif [ -e "$_dest" ]; then
        _backup=$(next_backup_path "$_dest")
        print_info "バックアップ: $_dest -> $_backup"
        if ! mv "$_dest" "$_backup" 2>/dev/null; then
            print_error "バックアップ失敗: $_dest"
            COUNT_ERROR=$((COUNT_ERROR + 1))
            return 1
        fi
        COUNT_BACKUP=$((COUNT_BACKUP + 1))
    fi

    return 0
}

new_stow_specs_file() {
    _stow_specs_file=$(mktemp)
    _TMPFILES="$_TMPFILES $_stow_specs_file"
}

home_relative_path() {
    case "$1" in
        "$HOME"/*)
            printf '%s\n' "${1#"$HOME"/}"
            ;;
        *)
            print_error "stow target は HOME 配下に限ります: $1"
            COUNT_ERROR=$((COUNT_ERROR + 1))
            return 1
            ;;
    esac
}

stow_specs_add() {
    _spec_file="$1"
    _source="$2"
    _dest="$3"

    if [ ! -e "${DOTFILES_DIR}/${_source}" ] && [ ! -L "${DOTFILES_DIR}/${_source}" ]; then
        print_skip "スキップ: ${DOTFILES_DIR}/${_source} (ファイルが存在しません)"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

    printf '%s:%s\n' "$_source" "$_dest" >> "$_spec_file"
}

stow_specs_add_dest() {
    _spec_file="$1"
    _source="$2"
    _dest="$3"
    _dest_rel=$(home_relative_path "$_dest") || return 1
    stow_specs_add "$_spec_file" "$_source" "$_dest_rel"
}

generate_ai_assets() {
    [ "$CLAUDE_SELECTED" = "true" ] || [ "$CODEX_SELECTED" = "true" ] || return 0

    _generator="${DOTFILES_DIR}/${AI_ASSET_GENERATOR_REL}"
    [ -f "$_generator" ] || die "AI asset generator が見つかりません: $_generator"
    print_info "common/* から Claude/Codex 用assetを生成・検証"
    python3 "$_generator" --repo "$DOTFILES_DIR" || die "AI asset の生成・検証に失敗しました"
    for _generated_dir in "$AI_CLAUDE_ASSETS" "$AI_CODEX_ASSETS" "$AI_PLUGIN_ASSETS"; do
        [ -d "${DOTFILES_DIR}/${_generated_dir}" ] || die "生成済みAI assetが不足しています: $_generated_dir"
    done
}

add_generated_ai_stow_specs() {
    _spec_file="$1"
    _target="$2"
    _package="$3"
    _previous_manifest="${DOTFILES_DIR}/.stow-work/.manifests/${_package}.links"

    if [ "$MODE_UNINSTALL" = "true" ]; then
        [ -s "$_previous_manifest" ] && cat "$_previous_manifest" >> "$_spec_file"
        return 0
    fi

    _generator="${DOTFILES_DIR}/${AI_ASSET_GENERATOR_REL}"
    _generated_manifest="${DOTFILES_DIR}/${AI_ASSET_ROOT_REL}/manifest.json"
    [ -f "$_generated_manifest" ] || return 0

    _generated_specs=$(mktemp)
    _TMPFILES="$_TMPFILES $_generated_specs"
    if ! python3 "$_generator" --repo "$DOTFILES_DIR" --list-target "$_target" > "$_generated_specs"; then
        print_error "生成済み ${_target} asset manifest の読み込みに失敗しました"
        COUNT_ERROR=$((COUNT_ERROR + 1))
        return 1
    fi
    cat "$_generated_specs" >> "$_spec_file"
}

prepare_stow_target_path() {
    _pst_package="$1"
    _pst_remaining="$2"
    _pst_relative=""

    # Never prepare a leaf through an ancestor symlink: that would modify
    # the linked source tree, while leaving the actual stow conflict intact.
    while :; do
        _pst_part=${_pst_remaining%%/*}
        _pst_relative=${_pst_relative:+${_pst_relative}/}${_pst_part}
        _pst_target="${HOME}/${_pst_relative}"
        _pst_entry=".stow-work/${_pst_package}/${_pst_relative}"

        if [ -L "$_pst_target" ]; then
            # Stow owns folded directory links and handles unfolding itself.
            # Stop here even for owned links; do not touch package contents.
            prepare_stow_target "$_pst_target" "$_pst_package" "$_pst_entry"
            return $?
        fi
        [ -e "$_pst_target" ] || return 0
        if [ "$_pst_remaining" = "$_pst_part" ] || [ ! -d "$_pst_target" ]; then
            prepare_stow_target "$_pst_target" "$_pst_package" "$_pst_entry"
            return $?
        fi
        _pst_remaining=${_pst_remaining#*/}
    done
}

prepare_stow_targets_from_file() {
    _package="$1"
    _spec_file="$2"
    _prepare_status=0

    while IFS= read -r _spec; do
        [ -z "$_spec" ] && continue
        _dest="${_spec#*:}"
        if prepare_stow_target_path "$_package" "$_dest"; then
            continue
        else
            _status=$?
        fi

        if [ "$_status" -eq 2 ]; then
            _prepare_status=2
            continue
        fi
        return "$_status"
    done < "$_spec_file"

    return "$_prepare_status"
}

run_stow_link_specs_file() {
    _package="$1"
    _mode="$2"
    _spec_file="$3"
    _script="${DOTFILES_DIR}/scripts/stow-install.sh"

    [ -s "$_spec_file" ] || return 0

    case "$_mode" in
        install|uninstall) ;;
        *)
            print_error "不明な stow mode: $_mode"
            COUNT_ERROR=$((COUNT_ERROR + 1))
            return 1
            ;;
    esac

    if [ ! -x "$_script" ]; then
        print_error "stow install script が見つからないか実行できません: $_script"
        COUNT_ERROR=$((COUNT_ERROR + 1))
        return 1
    fi

    set -- --repo "$DOTFILES_DIR" --target "$HOME" --package "$_package"
    while IFS= read -r _spec; do
        [ -z "$_spec" ] && continue
        if [ "$MODE_DRY_RUN" = "true" ]; then
            _source="${_spec%%:*}"
            _dest="${_spec#*:}"
            print_info "[ドライラン] stow link: ${HOME}/${_dest} <- ${DOTFILES_DIR}/${_source}"
        fi
        set -- "$@" --link "$_spec"
    done < "$_spec_file"
    [ "$MODE_DRY_RUN" = "true" ] && set -- "$@" --dry-run
    [ "$_mode" = "uninstall" ] && set -- "$@" --uninstall

    if "$_script" "$@"; then
        if [ "$_mode" = "uninstall" ]; then
            if [ "$MODE_DRY_RUN" = "true" ]; then
                print_info "[ドライラン] stow package 削除: $_package"
            else
                print_success "stow package 削除: $_package"
                COUNT_REMOVED=$((COUNT_REMOVED + 1))
            fi
        else
            if [ "$MODE_DRY_RUN" = "true" ]; then
                print_info "[ドライラン] stow package 作成: $_package"
            else
                print_success "stow package 作成: $_package"
            fi
            COUNT_CREATED=$((COUNT_CREATED + 1))
        fi
    else
        _status=$?
        print_error "stow package 処理失敗: $_package"
        COUNT_ERROR=$((COUNT_ERROR + 1))
        return "$_status"
    fi
}

install_stow_specs_file() {
    _package="$1"
    _spec_file="$2"

    [ -s "$_spec_file" ] || return 0

    if prepare_stow_targets_from_file "$_package" "$_spec_file"; then
        run_stow_link_specs_file "$_package" install "$_spec_file"
    else
        _status=$?
        [ "$_status" -eq 2 ] && return 0
        return "$_status"
    fi
}

uninstall_stow_specs_file() {
    _package="$1"
    _spec_file="$2"

    [ -s "$_spec_file" ] || return 0
    run_stow_link_specs_file "$_package" uninstall "$_spec_file"
}

run_stow_link() {
    _package="$1"
    _source="$2"
    _dest="$3"
    _mode="${4:-install}"

    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    stow_specs_add "$_spec_file" "$_source" "$_dest"
    run_stow_link_specs_file "$_package" "$_mode" "$_spec_file"
}

detect_platform() {
    if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] || [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
    elif [ "$(uname)" = "Darwin" ]; then
        echo "macos"
    else
        case "$(uname -s)" in
            CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
            *) echo "linux" ;;
        esac
    fi
}

detect_current_shell() {
    case "${SHELL:-}" in
        */bash) echo "bash" ;;
        */zsh)  echo "zsh" ;;
        */fish) echo "fish" ;;
        *)      echo "bash" ;;
    esac
}

get_shell_rc_display() {
    case "$1" in
        bash) echo "$HOME/.bashrc" ;;
        zsh)  echo "$HOME/.zshrc" ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
        all)  echo "$HOME/.bashrc, $HOME/.zshrc, $HOME/.config/fish/config.fish" ;;
        *)    echo "$HOME/.bashrc" ;;
    esac
}

# ============================================================================
# Link Primitives
# ============================================================================

remove_link() {
    _src="${DOTFILES_DIR}/$1"
    _dest="$2"

    [ -e "$_dest" ] || [ -L "$_dest" ] || return 0

    if [ ! -L "$_dest" ]; then
        print_skip "スキップ: $_dest (シンボリックリンクではありません)"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

    _target=$(readlink "$_dest" 2>/dev/null) || true
    _resolved_target=$(canonicalize_path "$_target")
    _resolved_src=$(canonicalize_path "$_src")
    if [ "$_resolved_target" != "$_resolved_src" ]; then
        print_skip "スキップ: $_dest (別の場所を指しています)"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] 削除: $_dest"
        return 0
    fi

    if rm "$_dest" 2>/dev/null; then
        print_success "削除: $_dest"
        COUNT_REMOVED=$((COUNT_REMOVED + 1))

        if [ -e "${_dest}.bak" ]; then
            if mv "${_dest}.bak" "$_dest" 2>/dev/null; then
                print_info "復元: ${_dest}.bak -> $_dest"
            else
                print_error "復元失敗: ${_dest}.bak"
            fi
        fi
    else
        print_error "削除失敗: $_dest"
        COUNT_ERROR=$((COUNT_ERROR + 1))
        return 1
    fi
}

# DOTFILES_DIR 向きのシンボリックリンクか
is_dotfiles_link() {
    [ ! -L "$1" ] && return 1
    _idl_target=$(readlink "$1" 2>/dev/null) || return 1
    _idl_target=$(absolute_path_without_following_leaf "$_idl_target" "$(dirname "$1")")
    case "$_idl_target" in "${DOTFILES_DIR}"/*) return 0 ;; *) return 1 ;; esac
}

# DOTFILES_DIR 向きのリンクのうち、git 管理外 (stale) か
_is_stale_link() {
    [ ! -L "$1" ] && return 1
    _sl_target=$(readlink "$1" 2>/dev/null) || return 1
    _sl_target=$(absolute_path_without_following_leaf "$_sl_target" "$(dirname "$1")")
    case "$_sl_target" in
        "${_csl_dotfiles}/.stow-work"/*)
            [ ! -e "$1" ] && return 0
            return 1
            ;;
        "${_csl_dotfiles}"/*) ;;
        *) return 1 ;;
    esac
    [ ! -e "$1" ] && return 0
    _sl_relative="${_sl_target#"${_csl_dotfiles}"/}"
    (cd "$DOTFILES_DIR" && git ls-files --error-unmatch "$_sl_relative" >/dev/null 2>&1) && return 1
    return 0
}

# パス/ディレクトリの削除 (ドライラン対応・エラー報告付き)
_remove_stale() {
    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] 削除: $2"
        return 0
    fi
    _rs_ok=false
    if [ "${3:-}" = "rf" ]; then
        rm -rf "$1" 2>/dev/null && _rs_ok=true
    else
        rm "$1" 2>/dev/null && _rs_ok=true
    fi
    if [ "$_rs_ok" = "true" ]; then
        print_info "削除: $2"
    else
        print_error "削除失敗: $2"
        COUNT_ERROR=$((COUNT_ERROR + 1))
    fi
}

# DOTFILES_DIR 向きリンクならラベル付きで削除
remove_dotfiles_link() {
    if is_dotfiles_link "$1"; then
        _remove_stale "$1" "$2"
    fi
}

# ============================================================================
# Cleanup Helpers
# ============================================================================

cleanup_stale_links_in() {
    _csl_label="$1"
    _csl_base="$2"
    shift 2
    _csl_dotfiles=$(canonicalize_path "$DOTFILES_DIR")

    for _dir in "$@"; do
        _target_dir="${_csl_base}/${_dir}"
        [ -d "$_target_dir" ] || continue
        for _entry in "$_target_dir"/*; do
            if [ -L "$_entry" ]; then
                _is_stale_link "$_entry" || continue
                _remove_stale "$_entry" "古い${_csl_label} ${_dir}: $(basename "$_entry")"
            elif [ -d "$_entry" ]; then
                _csl_dir_all_stale "$_entry" || continue
                _remove_stale "$_entry" "古い${_csl_label} ${_dir}: $(basename "$_entry")" rf
            fi
        done
    done
}

# ディレクトリの中身が全て stale リンクで埋まっているか (空ディレクトリは除外)
_csl_dir_all_stale() {
    _has_entries=false
    _all_stale=true
    for _f in "$1"/*; do
        [ ! -L "$_f" ] && [ ! -e "$_f" ] && continue
        _has_entries=true
        _is_stale_link "$_f" || { _all_stale=false; break; }
    done
    [ "$_has_entries" = "true" ] && [ "$_all_stale" = "true" ]
}

cleanup_legacy_claude_skill_tiers() {
    _skills_dir="${HOME}/.claude/skills"
    [ -d "$_skills_dir" ] || return 0

    for _entry in "$_skills_dir"/*; do
        case "$(basename "$_entry")" in
            1-core|2-domain|3-task|4-utility)
                if [ -L "$_entry" ]; then
                    remove_dotfiles_link "$_entry" "旧スキル構造: $(basename "$_entry")"
                    continue
                fi
                [ -d "$_entry" ] || continue

                _legacy_links=$(mktemp)
                _TMPFILES="$_TMPFILES $_legacy_links"
                find "$_entry" -type l -print > "$_legacy_links" 2>/dev/null || true
                while IFS= read -r _legacy_link; do
                    [ -n "$_legacy_link" ] || continue
                    remove_dotfiles_link \
                        "$_legacy_link" \
                        "旧スキル構造リンク: ${_legacy_link#"$HOME"/}"
                done < "$_legacy_links"
                ;;
        esac
    done
}

cleanup_removed_codex_links() {
    _remove_legacy_codex_files
    _remove_legacy_codex_skill_links
}

_remove_legacy_codex_files() {
    remove_dotfiles_link "${HOME}/.codex/README.md" "除外済みCodex README"
    remove_dotfiles_link "${HOME}/.codex/settings.json" "除外済みCodex settings.json"
    remove_dotfiles_link "${HOME}/.codex/reference/claude-settings.reference.json" "除外済みCodex reference"
}

_remove_legacy_codex_skill_links() {
    _skills_dir="${HOME}/.codex/skills"
    [ -d "$_skills_dir" ] || return 0

    for _entry in "$_skills_dir"/*; do
        [ -e "$_entry" ] || [ -L "$_entry" ] || continue

        if is_dotfiles_link "$_entry"; then
            _remove_stale "$_entry" "移行済みCodex skill: $(basename "$_entry")"
        elif [ -d "$_entry" ]; then
            _remove_codex_skill_dir_if_all_dotfiles_links "$_entry"
        fi
    done
}

_remove_codex_skill_dir_if_all_dotfiles_links() {
    _entry="$1"
    _has_entries=false
    _all_dotfiles_links=true
    for _f in "$_entry"/*; do
        [ -e "$_f" ] || [ -L "$_f" ] || continue
        _has_entries=true
        is_dotfiles_link "$_f" || { _all_dotfiles_links=false; break; }
    done
    [ "$_has_entries" = "true" ] && [ "$_all_dotfiles_links" = "true" ] || return 0
    _remove_stale "$_entry" "移行済みCodex skill: $(basename "$_entry")" rf
}

# ============================================================================
# Git
# ============================================================================

install_git_files() {
    cleanup_legacy_git_artifacts

    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    stow_specs_add "$_spec_file" "config/git/.git-completion.bash" ".git-completion.bash"
    stow_specs_add "$_spec_file" "config/git/.git-prompt.sh" ".git-prompt.sh"
    stow_specs_add "$_spec_file" "config/git/.git-prompt.sh" ".config/git/.git-prompt.sh"
    stow_specs_add "$_spec_file" "config/git/.gitattributes" ".config/git/attributes"
    install_stow_specs_file "git" "$_spec_file"
}

uninstall_git_files() {
    cleanup_legacy_git_artifacts

    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    stow_specs_add "$_spec_file" "config/git/.git-completion.bash" ".git-completion.bash"
    stow_specs_add "$_spec_file" "config/git/.git-prompt.sh" ".git-prompt.sh"
    stow_specs_add "$_spec_file" "config/git/.git-prompt.sh" ".config/git/.git-prompt.sh"
    stow_specs_add "$_spec_file" "config/git/.gitattributes" ".config/git/attributes"
    uninstall_stow_specs_file "git" "$_spec_file"

    remove_link "config/git/.git-completion.bash" "${HOME}/.git-completion.bash"
    remove_link "config/git/.git-prompt.sh"        "${HOME}/.git-prompt.sh"
    remove_link "config/git/.git-prompt.sh"        "${HOME}/.config/git/.git-prompt.sh"
    remove_link "config/git/.gitattributes"        "${HOME}/.config/git/attributes"
}

# 旧配置 (命名変遷の名残) の残骸を除去する。
# dotfiles 由来リンクのみ remove_dotfiles_link で安全に削除し、
# 判定不能な実体 ~/.gitignore は誤削除を避け手動削除を案内する。
cleanup_legacy_git_artifacts() {
    remove_dotfiles_link "${HOME}/.gitignore_global"        "旧gitignore_globalリンク"
    remove_dotfiles_link "${HOME}/.gitignore.common"        "旧gitignore.commonリンク"
    remove_dotfiles_link "${HOME}/.config/git/.gitattributes" "旧gitattributesリンク (ドット付き)"

    _legacy_ignore="${HOME}/.gitignore"
    if is_dotfiles_link "$_legacy_ignore"; then
        remove_dotfiles_link "$_legacy_ignore" "旧gitignoreリンク"
    elif [ -f "$_legacy_ignore" ]; then
        print_info "残骸の可能性: ${_legacy_ignore} (旧 excludesfile 実体)。不要なら手動削除してください"
    fi
}

install_gitignore() {
    [ -z "$GITCONFIG_VARIANT" ] && return 0

    _target="${HOME}/.config/git/ignore"
    _base="${DOTFILES_DIR}/config/git/.gitignore.common"
    _variant="${DOTFILES_DIR}/config/git/.gitignore.${GITCONFIG_VARIANT}"

    if [ "$MODE_DRY_RUN" = "true" ]; then
        printf "%s[DRY-RUN]%s Would create: %s (base + %s)\n" "$COLOR_YELLOW" "$COLOR_RESET" "$_target" "$GITCONFIG_VARIANT"
        return 0
    fi

    _gitignore_validate_variant "$_variant" || return 1
    ensure_dir "${HOME}/.config/git" || return 1
    _gitignore_target_matches_merged "$_base" "$_variant" "$_target" && return 0
    _gitignore_backup_existing "$_target"
    _gitignore_merge_and_write "$_base" "$_variant" "$_target"
}

_gitignore_validate_variant() {
    [ -f "$1" ] && return 0
    printf "%s[ERROR]%s variant not found: %s\n" "$COLOR_RED" "$COLOR_RESET" "$1"
    return 1
}

_gitignore_target_matches_merged() {
    _base="$1"
    _variant="$2"
    _target="$3"

    [ -f "$_target" ] && [ ! -L "$_target" ] || return 1

    _merged=$(mktemp)
    _TMPFILES="$_TMPFILES $_merged"
    cat "$_base" "$_variant" > "$_merged"
    cmp -s "$_merged" "$_target"
}

_gitignore_backup_existing() {
    _target="$1"
    [ -f "$_target" ] || [ -L "$_target" ] || return 0

    if [ -L "$_target" ]; then
        rm "$_target"
    else
        _backup=$(next_backup_path "$_target")
        mv "$_target" "$_backup"
        printf "%s[BACKUP]%s %s -> %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$_target" "$_backup"
    fi
}

_gitignore_merge_and_write() {
    cat "$1" "$2" > "$3"
    printf "%s[CREATE]%s %s (base + %s)\n" "$COLOR_GREEN" "$COLOR_RESET" "$3" "$GITCONFIG_VARIANT"
}

install_gitconfig_common() {
    _target="${HOME}/.gitconfig.common"
    _source="${DOTFILES_DIR}/config/git/.gitconfig.common"

    if [ "$MODE_DRY_RUN" = "true" ]; then
        printf "%s[DRY-RUN]%s Would create: %s (copy)\n" "$COLOR_YELLOW" "$COLOR_RESET" "$_target"
        return 0
    fi

    ensure_dir "$(dirname "$_target")" || return 1
    if [ -f "$_target" ] && [ ! -L "$_target" ] && cmp -s "$_source" "$_target"; then
        return 0
    fi

    if [ -L "$_target" ]; then
        rm "$_target"
    elif [ -e "$_target" ]; then
        _backup=$(next_backup_path "$_target")
        mv "$_target" "$_backup"
        printf "%s[BACKUP]%s %s -> %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$_target" "$_backup"
    fi

    cp "$_source" "$_target"
    printf "%s[CREATE]%s %s (copy)\n" "$COLOR_GREEN" "$COLOR_RESET" "$_target"
}

uninstall_gitconfig_common() {
    _target="${HOME}/.gitconfig.common"
    _source="${DOTFILES_DIR}/config/git/.gitconfig.common"

    if [ -f "$_target" ] && [ ! -L "$_target" ] && cmp -s "$_source" "$_target"; then
        rm "$_target"
        printf "%s[REMOVE]%s %s\n" "$COLOR_RED" "$COLOR_RESET" "$_target"
    else
        remove_link "config/git/.gitconfig.common" "$_target"
    fi

    if [ -f "${_target}.bak" ]; then
        mv "${_target}.bak" "$_target"
        printf "%s[RESTORE]%s %s.bak -> %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$_target" "$_target"
    fi
}

uninstall_gitignore() {
    _target="${HOME}/.config/git/ignore"

    if [ -f "$_target" ]; then
        rm "$_target"
        printf "%s[REMOVE]%s %s\n" "$COLOR_RED" "$COLOR_RESET" "$_target"
    fi

    if [ -f "${_target}.bak" ]; then
        mv "${_target}.bak" "$_target"
        printf "%s[RESTORE]%s %s.bak -> %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$_target" "$_target"
    fi
}

select_gitconfig_variant() {
    [ -n "$GITCONFIG_VARIANT" ] && return 0

    echo ""
    printf "${COLOR_BOLD}.gitconfigの環境を選択:${COLOR_RESET}\n"
    printf "  ${COLOR_BOLD}1)${COLOR_RESET} プライベート用 (macOS: /Users/...)\n"
    printf "  ${COLOR_BOLD}2)${COLOR_RESET} 仕事用 (Linux: /home/...)\n"
    echo ""
    printf "選択 (1/2): "
    read -r _choice

    case "$_choice" in
        1) GITCONFIG_VARIANT="private" ;;
        2) GITCONFIG_VARIANT="work" ;;
        *)
            print_error "無効な選択です。プライベート用を使用します"
            GITCONFIG_VARIANT="private"
            ;;
    esac

    print_success ".gitconfig: ${GITCONFIG_VARIANT} を選択しました"
}

install_gitconfig() {
    [ -z "$GITCONFIG_VARIANT" ] && return 0
    install_gitconfig_common || return 1

    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    stow_specs_add "$_spec_file" "config/git/.gitconfig.${GITCONFIG_VARIANT}" ".gitconfig"
    install_stow_specs_file "gitconfig" "$_spec_file"
}

uninstall_gitconfig() {
    _variant="${GITCONFIG_VARIANT:-work}"
    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    stow_specs_add "$_spec_file" "config/git/.gitconfig.${_variant}" ".gitconfig"
    uninstall_stow_specs_file "gitconfig" "$_spec_file"

    uninstall_gitconfig_common
    _target=$(readlink "${HOME}/.gitconfig" 2>/dev/null) || true
    case "$_target" in
        */.gitconfig.work)    remove_link "config/git/.gitconfig.work"    "${HOME}/.gitconfig" ;;
        */.gitconfig.private) remove_link "config/git/.gitconfig.private" "${HOME}/.gitconfig" ;;
    esac
}

# ============================================================================
# Vim
# ============================================================================

install_vim_files() {
    if prepare_stow_target "${HOME}/.vimrc" "vim" ".stow-work/vim/.vimrc"; then
        run_stow_link "vim" "config/vim/.vimrc" ".vimrc"
    else
        _status=$?
        [ "$_status" -eq 2 ] && return 0
        return "$_status"
    fi
}

uninstall_vim_files() {
    _dest="${HOME}/.vimrc"
    [ -e "$_dest" ] || [ -L "$_dest" ] || return 0

    if link_points_to_repo_entry "$_dest" "config/vim/.vimrc"; then
        remove_link "config/vim/.vimrc" "$_dest"
    elif link_points_to_repo_entry "$_dest" "stow/vim/.vimrc"; then
        remove_link "stow/vim/.vimrc" "$_dest"
    elif link_points_to_repo_entry "$_dest" ".stow-work/vim/.vimrc"; then
        run_stow_link "vim" "config/vim/.vimrc" ".vimrc" "uninstall"
    else
        print_skip "スキップ: $_dest (別の場所を指しています)"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    fi
}

# ============================================================================
# Shell
# ============================================================================

select_shell_type() {
    [ -n "$SHELL_TYPE" ] && return 0

    _current_shell=$(detect_current_shell)

    echo ""
    printf "${COLOR_BOLD}シェル設定を選択:${COLOR_RESET}\n"
    printf "  ${COLOR_BOLD}1)${COLOR_RESET} bash のみ\n"
    printf "  ${COLOR_BOLD}2)${COLOR_RESET} zsh のみ\n"
    printf "  ${COLOR_BOLD}3)${COLOR_RESET} fish のみ\n"
    printf "  ${COLOR_BOLD}4)${COLOR_RESET} すべて (bash + zsh + fish)\n"
    printf "  ${COLOR_BOLD}5)${COLOR_RESET} 現在のシェル (%s) のみ\n" "$_current_shell"
    echo ""
    printf "選択 (1-5) [5]: "
    read -r _choice

    case "$_choice" in
        1)    SHELL_TYPE="bash" ;;
        2)    SHELL_TYPE="zsh" ;;
        3)    SHELL_TYPE="fish" ;;
        4)    SHELL_TYPE="all" ;;
        5|"") SHELL_TYPE="$_current_shell" ;;
        *)
            print_error "無効な選択です。現在のシェルを使用します"
            SHELL_TYPE="$_current_shell"
            ;;
    esac

    print_success "シェル設定: ${SHELL_TYPE}"
}

select_shell_components() {
    echo ""
    printf "${COLOR_BOLD}インストールする内容を選択:${COLOR_RESET}\n"
    _shell_rc=$(get_shell_rc_display "$SHELL_TYPE")
    printf "  ${COLOR_BOLD}1)${COLOR_RESET} フルセット (既存設定を置き換え) ${COLOR_RED}⚠ 破壊的${COLOR_RESET}\n"
    printf "     → %s 等をリポジトリのものに置換 (既存は .bak にバックアップ)\n" "$_shell_rc"
    printf "  ${COLOR_BOLD}2)${COLOR_RESET} 追記モード (既存設定を保持) ${COLOR_GREEN}★推奨${COLOR_RESET}\n"
    printf "     → 既存の %s にsource行を自動挿入\n" "$_shell_rc"
    echo ""
    printf "選択 (1-2) [2]: "
    read -r _choice

    case "$_choice" in
        1)    SHELL_COMPONENTS="full";   print_success "フルセットを選択しました" ;;
        2|"") SHELL_COMPONENTS="append"; print_success "追記モードを選択しました" ;;
        *)
            print_error "無効な選択です。追記モードを使用します"
            SHELL_COMPONENTS="append"
            ;;
    esac
}

install_shell_config() {
    [ "$SHELL_SELECTED" != "true" ] && return 0
    print_header "シェル設定をインストール"

    case "$SHELL_COMPONENTS" in
        full)   install_shell_full ;;
        append) install_shell_append ;;
    esac
}

install_shell_full() {
    new_stow_specs_file
    _spec_file="$_stow_specs_file"

    case "$SHELL_TYPE" in
        bash)
            add_shell_full_stow_specs "$_spec_file" bash
            ;;
        zsh)
            add_shell_full_stow_specs "$_spec_file" zsh
            ;;
        fish)
            add_shell_full_stow_specs "$_spec_file" fish
            ;;
        all)
            add_shell_full_stow_specs "$_spec_file" all
            ;;
    esac

    install_stow_specs_file "shell" "$_spec_file"
}

add_shell_full_stow_specs() {
    _spec_file="$1"
    _shell="$2"

    case "$_shell" in
        bash|all)
            stow_specs_add "$_spec_file" "config/shell/bash/bashrc" ".bashrc"
            stow_specs_add "$_spec_file" "config/shell/bash/bash_profile" ".bash_profile"
            ;;
    esac

    case "$_shell" in
        zsh|all)
            stow_specs_add "$_spec_file" "config/shell/zsh/zshrc" ".zshrc"
            stow_specs_add "$_spec_file" "config/shell/zsh/zprofile" ".zprofile"
            ;;
    esac

    case "$_shell" in
        fish|all)
            stow_specs_add "$_spec_file" "config/shell/fish/config.fish" ".config/fish/config.fish"
            ;;
    esac
}

# 追記モード共通実装。シェル固有の source 行構文だけ引数で受ける
_inject_source_with_line() {
    _target_rc="$1"
    _source_line="$2"

    [ -f "$_target_rc" ] || { print_skip "スキップ: $_target_rc (ファイルが存在しません)"; return 0; }

    if grep -qF "$DOTWORK_MARKER_BEGIN" "$_target_rc" 2>/dev/null; then
        print_skip "スキップ: $_target_rc (source行は挿入済み)"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] source行を挿入: $_target_rc"
        COUNT_CREATED=$((COUNT_CREATED + 1))
        return 0
    fi

    _ensure_trailing_newline "$_target_rc"

    cat >> "$_target_rc" << EOF

$DOTWORK_MARKER_BEGIN
$_source_line
$DOTWORK_MARKER_END
EOF

    print_success "source行を挿入: $_target_rc"
    COUNT_CREATED=$((COUNT_CREATED + 1))
}

_ensure_trailing_newline() {
    _file="$1"
    [ -s "$_file" ] || return 0
    _tail=$(tail -c 1 "$_file" 2>/dev/null | wc -l)
    [ "$_tail" -eq 0 ] && printf '\n' >> "$_file"
}

inject_source_block() {
    _inject_source_with_line "$1" '[ -f "$HOME/.shell_common" ] && . "$HOME/.shell_common"'
}

inject_source_block_fish() {
    _inject_source_with_line "$1" 'bass source "$HOME/.shell_common"'
    print_info "注意: fishでは bass プラグインが必要です (fisher install edc/bass)"
}

remove_source_block() {
    _target_rc="$1"
    [ -f "$_target_rc" ] || return 0
    grep -qF "$DOTWORK_MARKER_BEGIN" "$_target_rc" 2>/dev/null || return 0

    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] source行を削除: $_target_rc"
        return 0
    fi

    _tmp="${_target_rc}.dotwork_tmp"
    _in_block=false
    while IFS= read -r _line || [ -n "$_line" ]; do
        case "$_line" in
            *"$DOTWORK_MARKER_BEGIN"*) _in_block=true;  continue ;;
            *"$DOTWORK_MARKER_END"*)   _in_block=false; continue ;;
        esac
        [ "$_in_block" = "false" ] && printf '%s\n' "$_line"
    done < "$_target_rc" > "$_tmp"

    mv "$_tmp" "$_target_rc"

    print_success "source行を削除: $_target_rc"
    COUNT_REMOVED=$((COUNT_REMOVED + 1))
}

install_shell_append() {
    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    stow_specs_add "$_spec_file" "config/shell/common.sh" ".shell_common"
    install_stow_specs_file "shell-common" "$_spec_file"

    case "$SHELL_TYPE" in
        bash) inject_source_block "${HOME}/.bashrc" ;;
        zsh)  inject_source_block "${HOME}/.zshrc" ;;
        fish)
            ensure_dir "${HOME}/.config/fish"
            inject_source_block_fish "${HOME}/.config/fish/config.fish"
            ;;
        all)
            inject_source_block "${HOME}/.bashrc"
            inject_source_block "${HOME}/.zshrc"
            ensure_dir "${HOME}/.config/fish"
            inject_source_block_fish "${HOME}/.config/fish/config.fish"
            ;;
    esac
}

uninstall_shell_config() {
    print_header "シェル設定をアンインストール"

    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    add_shell_full_stow_specs "$_spec_file" all
    uninstall_stow_specs_file "shell" "$_spec_file"

    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    stow_specs_add "$_spec_file" "config/shell/common.sh" ".shell_common"
    uninstall_stow_specs_file "shell-common" "$_spec_file"

    remove_link "config/shell/bash/bashrc"       "${HOME}/.bashrc"
    remove_link "config/shell/bash/bash_profile" "${HOME}/.bash_profile"
    remove_link "config/shell/zsh/zshrc"         "${HOME}/.zshrc"
    remove_link "config/shell/zsh/zprofile"      "${HOME}/.zprofile"
    remove_link "config/shell/fish/config.fish"  "${HOME}/.config/fish/config.fish"

    remove_link "config/shell/common.sh"         "${HOME}/.shell_common"
    remove_source_block "${HOME}/.bashrc"
    remove_source_block "${HOME}/.zshrc"
    remove_source_block "${HOME}/.config/fish/config.fish"
}

# ============================================================================
# Bin (CLI ツール)
# ============================================================================

install_bin_files() {
    [ "$BIN_SELECTED" != "true" ] && return 0
    print_header "CLIツールをインストール"

    new_stow_specs_file
    _spec_file="$_stow_specs_file"

    for _bin_file in "$DOTFILES_DIR"/bin/*; do
        [ -f "$_bin_file" ] || continue
        _name=$(basename "$_bin_file")
        stow_specs_add "$_spec_file" "bin/$_name" ".local/bin/$_name"
    done

    install_stow_specs_file "bin" "$_spec_file"
}

uninstall_bin_files() {
    new_stow_specs_file
    _spec_file="$_stow_specs_file"

    for _bin_file in "$DOTFILES_DIR"/bin/*; do
        [ -f "$_bin_file" ] || continue
        _name=$(basename "$_bin_file")
        stow_specs_add "$_spec_file" "bin/$_name" ".local/bin/$_name"
    done

    uninstall_stow_specs_file "bin" "$_spec_file"

    for _bin_file in "$DOTFILES_DIR"/bin/*; do
        [ -f "$_bin_file" ] || continue
        _name=$(basename "$_bin_file")
        remove_link "bin/$_name" "${HOME}/.local/bin/$_name"
    done
}

# ============================================================================
# Common shared assets
# ============================================================================

add_common_hooks_stow_specs() {
    _spec_file="$1"
    _dest_prefix="$2"

    for _file_path in "$DOTFILES_DIR"/"$COMMON_HOOKS"/*.sh; do
        [ -f "$_file_path" ] || continue
        _relative=$(basename "$_file_path")
        stow_specs_add "$_spec_file" "${COMMON_HOOKS}/${_relative}" "${_dest_prefix}/${_relative}"
    done
}

remove_legacy_common_hook_links() {
    _dest_dir="$1"

    for _file_path in "$DOTFILES_DIR"/"$COMMON_HOOKS"/*.sh; do
        [ -f "$_file_path" ] || continue
        _relative=$(basename "$_file_path")
        _dest="${_dest_dir}/${_relative}"
        [ -e "$_dest" ] || [ -L "$_dest" ] || continue
        remove_dotfiles_link "$_dest" "旧common hook: ${_relative}"
    done
}

add_common_qa_nightmare_checklists_stow_specs() {
    _spec_file="$1"
    _dest_prefix="$2"

    for _file_path in "$DOTFILES_DIR"/"$COMMON_QA_NIGHTMARE_CHECKLISTS"/*.md; do
        [ -f "$_file_path" ] || continue
        _relative=$(basename "$_file_path")
        stow_specs_add "$_spec_file" "${COMMON_QA_NIGHTMARE_CHECKLISTS}/${_relative}" "${_dest_prefix}/${_relative}"
    done
}

add_common_qa_nightmare_manifest_stow_spec() {
    _spec_file="$1"
    _dest_prefix="$2"

    stow_specs_add "$_spec_file" "$COMMON_QA_NIGHTMARE_MANIFEST" "${_dest_prefix}/manifest.json"
}

remove_legacy_qa_nightmare_checklist_links() {
    _dest_dir="$1"
    [ -d "$_dest_dir" ] || return 0

    for _entry in "$_dest_dir"/*; do
        [ -e "$_entry" ] || [ -L "$_entry" ] || continue
        remove_dotfiles_link "$_entry" "旧qa-nightmare checklist: $(basename "$_entry")"
    done
}

# ============================================================================
# Claude
# ============================================================================

install_claude_config() {
    [ "$CLAUDE_SELECTED" != "true" ] && return 0
    print_header "Claude設定をインストール"

    _claude_ensure_directories
    _claude_cleanup_stale
    _claude_install_stow_package
    _claude_setup_vendor_skills
}

_claude_ensure_directories() {
    ensure_dir "${HOME}/.claude"
    ensure_dir "${HOME}/.claude/bin"
    ensure_dir "${HOME}/.claude/hooks"
    ensure_dir "${HOME}/.claude/skills"
    ensure_dir "${HOME}/.claude/rules"
}

_claude_cleanup_stale() {
    cleanup_legacy_claude_skill_tiers
    remove_dotfiles_link "${HOME}/.claude/statusline.settings.json" "旧Claude statusline.settings.json"
    cleanup_stale_links_in "Claude" "${HOME}/.claude" bin commands hooks skills rules
}

_claude_install_stow_package() {
    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    _claude_add_managed_stow_specs "$_spec_file"
    install_stow_specs_file "claude" "$_spec_file"
}

_claude_uninstall_stow_package() {
    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    _claude_add_managed_stow_specs "$_spec_file"
    uninstall_stow_specs_file "claude" "$_spec_file"
}

_claude_add_managed_stow_specs() {
    _spec_file="$1"
    add_generated_ai_stow_specs "$_spec_file" claude claude
}

_claude_setup_vendor_skills() {
    _vendor_dir="${HOME}/.claude/vendor"
    _agent_skills_dir="${_vendor_dir}/agent-skills"
    ensure_dir "$_vendor_dir"

    _claude_vendor_clone_if_missing "$_agent_skills_dir"

    [ -d "$_agent_skills_dir/skills" ] || return 0
    for _skill in $VENDOR_SKILLS; do
        _claude_vendor_link_skill "$_agent_skills_dir" "$_skill"
    done
}

_claude_vendor_clone_if_missing() {
    [ -d "${1}/.git" ] && return 0

    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] vendor: agent-skills を取得"
        return 0
    fi

    if (
        unset GIT_INDEX_FILE
        git clone --depth 1 --quiet "https://github.com/vercel-labs/agent-skills.git" "$1" 2>/dev/null
    ); then
        print_success "取得: vendor/agent-skills"
    else
        print_skip "vendor/agent-skills の取得に失敗（オフライン？）"
    fi
}

_claude_vendor_link_skill() {
    _src="${1}/skills/${2}"
    _dest="${HOME}/.claude/skills/${2}"

    [ -L "$_dest" ] && [ ! -e "$_dest" ] && rm "$_dest" 2>/dev/null

    [ -e "$_src" ]  || return 0
    [ -e "$_dest" ] && return 0

    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] リンク: ~/.claude/skills/${2}"
        return 0
    fi

    if ln -s "$_src" "$_dest"; then
        print_success "作成: ~/.claude/skills/${2}"
    else
        print_error "リンク作成失敗: ${2}"
    fi
}

uninstall_claude_config() {
    print_header "Claude設定をアンインストール"

    _claude_cleanup_stale
    _claude_uninstall_stow_package
    _claude_unlink_managed_files
    remove_legacy_common_hook_links "${HOME}/.claude/hooks"
    remove_legacy_qa_nightmare_checklist_links "${HOME}/.claude/skills/qa-nightmare/checklists"
    _claude_unlink_vendor_skills
    _claude_prune_empty_dirs
}

_claude_unlink_managed_files() {
    [ -d "${DOTFILES_DIR}/claude" ] || return 0

    _filelist=$(mktemp)
    _TMPFILES="$_TMPFILES $_filelist"
    (cd "$DOTFILES_DIR" && git ls-files claude/ 2>/dev/null) > "$_filelist"

    while IFS= read -r _file; do
        [ -z "$_file" ] && continue

        _relative="${_file#claude/}"
        case "$_relative" in CLAUDE.md) continue ;; esac

        _dest_relative=$(claude_target_relative "$_relative")
        _dest="${HOME}/.claude/${_dest_relative}"
        remove_link "$_file" "$_dest"
    done < "$_filelist"

    rm -f "$_filelist"
}

_claude_unlink_vendor_skills() {
    for _skill in $VENDOR_SKILLS; do
        _dest="${HOME}/.claude/skills/${_skill}"
        [ -L "$_dest" ] || continue
        if [ "$MODE_DRY_RUN" = "true" ]; then
            print_info "[ドライラン] 削除: ~/.claude/skills/${_skill}"
        else
            rm "$_dest" && print_success "削除: ${HOME}/.claude/skills/${_skill}"
        fi
    done

    [ -d "${HOME}/.claude/vendor/agent-skills" ] || return 0
    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] 削除: ~/.claude/vendor/agent-skills"
    else
        rm -rf "${HOME}/.claude/vendor/agent-skills" && print_success "削除: ~/.claude/vendor/agent-skills"
        rmdir "${HOME}/.claude/vendor" 2>/dev/null || true
    fi
}

_claude_prune_empty_dirs() {
    _count=$(find "${HOME}/.claude" -mindepth 1 -depth -type d 2>/dev/null \
        | while IFS= read -r _dir; do rmdir "$_dir" 2>/dev/null && echo x; done \
        | wc -l)
    if [ "$_count" -gt 0 ]; then
        print_success "空ディレクトリ削除: .claude/ 配下 ${_count} 件"
    fi
}

# ============================================================================
# Codex
# ============================================================================

codex_dest_for_relative() {
    case "$1" in
        global_AGENTS.md)
            printf '%s/.codex/AGENTS.md\n' "$HOME"
            ;;
        SUBAGENTS.md)
            printf '%s/.codex/%s\n' "$HOME" "$1"
            ;;
        agents/*.toml|agents/*/checklists/*.md|bin/*|hooks/*|rules/*.md|rules/*.rules)
            printf '%s/.codex/%s\n' "$HOME" "$1"
            ;;
        */*.config.toml)
            return 1
            ;;
        *.config.toml)
            printf '%s/.codex/%s\n' "$HOME" "$1"
            ;;
        config.toml|config.toml.template|hooks.json)
            return 1
            ;;
        skills/*/SKILL.md|skills/*/agents/openai.yaml)
            # Plugin-only mode: skills are distributed via plugins.
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

install_codex_config() {
    [ "$CODEX_SELECTED" != "true" ] && return 0
    print_header "Codex設定をインストール"

    _codex_ensure_directories
    _codex_cleanup_all
    _codex_install_stow_package
    _codex_generate_config_from_template
    _codex_warn_legacy_hooks_json
    _codex_verify_hooks_feature
}

_codex_ensure_directories() {
    ensure_dir "${HOME}/.codex"
    ensure_dir "${HOME}/.codex/agents"
    ensure_dir "${HOME}/.codex/bin"
    ensure_dir "${HOME}/.codex/hooks"
    ensure_dir "${HOME}/.codex/rules"
    ensure_dir "${HOME}/.codex/plugins"
    ensure_dir "${HOME}/.agents/plugins"
}

_codex_cleanup_all() {
    cleanup_stale_links_in "Codex"       "${HOME}/.codex"  agents bin hooks plugins rules skills
    cleanup_removed_codex_links
    cleanup_stale_links_in "Codex shared" "${HOME}/.agents" plugins skills
}

_codex_install_stow_package() {
    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    _codex_add_managed_stow_specs "$_spec_file"
    install_stow_specs_file "codex" "$_spec_file"
}

_codex_uninstall_stow_package() {
    new_stow_specs_file
    _spec_file="$_stow_specs_file"
    _codex_add_managed_stow_specs "$_spec_file"
    uninstall_stow_specs_file "codex" "$_spec_file"
}

_codex_add_managed_stow_specs() {
    _spec_file="$1"
    add_generated_ai_stow_specs "$_spec_file" codex codex
}

_codex_generate_config_from_template() {
    _template="${DOTFILES_DIR}/codex/config.toml.template"
    _dest="${HOME}/.codex/config.toml"

    if [ ! -f "$_template" ]; then
        print_skip "スキップ: codex/config.toml.template (ファイルが存在しません)"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

    if [ -e "$_dest" ] || [ -L "$_dest" ]; then
        print_info "既存の ~/.codex/config.toml は上書きしません。codex/config.toml.template を手動 merge してください"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

    if [ "$MODE_DRY_RUN" = "true" ]; then
        print_info "[ドライラン] 生成: ~/.codex/config.toml <- codex/config.toml.template"
        COUNT_CREATED=$((COUNT_CREATED + 1))
        return 0
    fi

    ensure_dir "$(dirname "$_dest")" || return 1
    if cp "$_template" "$_dest" 2>/dev/null; then
        print_success "生成: ~/.codex/config.toml"
        COUNT_CREATED=$((COUNT_CREATED + 1))
    else
        print_error "生成失敗: ~/.codex/config.toml"
        COUNT_ERROR=$((COUNT_ERROR + 1))
        return 1
    fi
}

_codex_warn_legacy_hooks_json() {
    _hooks_json="${HOME}/.codex/hooks.json"
    [ -e "$_hooks_json" ] || [ -L "$_hooks_json" ] || return 0
    print_info "既存の ~/.codex/hooks.json は自動削除しません。inline hooks へ移行済みのため必要なら手動で退避してください"
    COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
}

_codex_verify_hooks_feature() {
    command -v codex >/dev/null 2>&1 || return 0

    if codex features list 2>/dev/null | grep -q '^hooks[[:space:]]'; then
        print_success "Codex hooks feature: 利用可能"
    elif codex features list 2>/dev/null | grep -q '^codex_hooks[[:space:]]'; then
        print_info "Codex hooks feature: codex_hooks を有効化してください (codex features enable codex_hooks)"
    fi
}

uninstall_codex_config() {
    print_header "Codex設定をアンインストール"

    _codex_cleanup_all
    _codex_uninstall_stow_package
    _codex_unlink_managed_files
    remove_legacy_common_hook_links "${HOME}/.codex/hooks"
    remove_legacy_qa_nightmare_checklist_links "${HOME}/.codex/agents/qa-nightmare/checklists"
    _codex_prune_empty_dirs
}

_codex_unlink_managed_files() {
    [ -d "${DOTFILES_DIR}/codex" ] || return 0

    _filelist=$(mktemp)
    _TMPFILES="$_TMPFILES $_filelist"
    (cd "$DOTFILES_DIR" && git ls-files codex/ 2>/dev/null) > "$_filelist"

    while IFS= read -r _file; do
        [ -z "$_file" ] && continue

        _relative="${_file#codex/}"
        _dest=$(codex_dest_for_relative "$_relative") || continue
        remove_link "$_file" "$_dest"
    done < "$_filelist"

    rm -f "$_filelist"
}

_codex_prune_empty_dirs() {
    _count=$(find "${HOME}/.codex" -mindepth 1 -depth -type d 2>/dev/null \
        | while IFS= read -r _dir; do rmdir "$_dir" 2>/dev/null && echo x; done \
        | wc -l)
    if [ "$_count" -gt 0 ]; then
        print_success "空ディレクトリ削除: .codex/ 配下 ${_count} 件"
    fi
}

# ============================================================================
# Interactive UI
# ============================================================================

select_uninstall_components() {
    echo ""
    printf "${COLOR_BOLD}アンインストールするカテゴリを選択 (複数可、スペース区切り):${COLOR_RESET}\n"
    printf "  ${COLOR_BOLD}1)${COLOR_RESET} シェル設定\n"
    printf "  ${COLOR_BOLD}2)${COLOR_RESET} Git設定\n"
    printf "  ${COLOR_BOLD}3)${COLOR_RESET} Vim設定\n"
    printf "  ${COLOR_BOLD}4)${COLOR_RESET} CLIツール\n"
    printf "  ${COLOR_BOLD}5)${COLOR_RESET} Claude Code設定\n"
    printf "  ${COLOR_BOLD}6)${COLOR_RESET} Codex設定\n"
    printf "  ${COLOR_BOLD}a)${COLOR_RESET} すべて\n"
    echo ""
    printf "選択 (例: 1 3 / a) [a]: "
    read -r _choices

    case "$_choices" in
        a|A|"")
            UNINSTALL_SHELL=true
            UNINSTALL_GIT=true
            UNINSTALL_VIM=true
            UNINSTALL_BIN=true
            UNINSTALL_CLAUDE=true
            UNINSTALL_CODEX=true
            ;;
        *)
            for _c in $_choices; do
                case "$_c" in
                    1) UNINSTALL_SHELL=true ;;
                    2) UNINSTALL_GIT=true ;;
                    3) UNINSTALL_VIM=true ;;
                    4) UNINSTALL_BIN=true ;;
                    5) UNINSTALL_CLAUDE=true ;;
                    6) UNINSTALL_CODEX=true ;;
                    *) print_error "無効な選択をスキップ: $_c" ;;
                esac
            done
            ;;
    esac

    _selected=""
    [ "$UNINSTALL_SHELL" = "true" ]  && _selected="${_selected}シェル "
    [ "$UNINSTALL_GIT" = "true" ]    && _selected="${_selected}Git "
    [ "$UNINSTALL_VIM" = "true" ]    && _selected="${_selected}Vim "
    [ "$UNINSTALL_BIN" = "true" ]    && _selected="${_selected}CLIツール "
    [ "$UNINSTALL_CLAUDE" = "true" ] && _selected="${_selected}Claude "
    [ "$UNINSTALL_CODEX" = "true" ]  && _selected="${_selected}Codex "

    [ -z "$_selected" ] && die "カテゴリが選択されていません"

    print_success "アンインストール対象: ${_selected}"
}

show_category_menu() {
    print_header "インストールするカテゴリを選択"
    echo ""
    printf "  ${COLOR_BOLD}1)${COLOR_RESET} シェル設定\n"
    printf "     PATH, エイリアス, プロンプト, SSH Agent を設定\n"
    printf "  ${COLOR_BOLD}2)${COLOR_RESET} Git設定\n"
    printf "     gitconfig, 補完, gitignore を設定\n"
    printf "  ${COLOR_BOLD}3)${COLOR_RESET} Vim設定\n"
    printf "     .vimrc を配置\n"
    printf "  ${COLOR_BOLD}4)${COLOR_RESET} CLIツール\n"
    printf "     git-new-feature 等を ~/.local/bin/ に配置\n"
    printf "  ${COLOR_BOLD}5)${COLOR_RESET} Claude Code設定\n"
    printf "     hooks, skills, rules, commands を ~/.claude/ に配置\n"
    printf "  ${COLOR_BOLD}6)${COLOR_RESET} Codex設定\n"
    printf "     agents, inline hooks template, rules を ~/.codex/ に配置 (skills は plugin 配布)\n"
    echo ""
    printf "  ${COLOR_BOLD}a)${COLOR_RESET} すべて  ${COLOR_BOLD}q)${COLOR_RESET} 終了\n"
    echo ""
}

select_files_interactive() {
    while true; do
        show_category_menu
        printf "カテゴリを選択 (1-6/a/q): "
        read -r _choice

        case "$_choice" in
            q|Q)
                echo "キャンセルしました。"
                exit 0
                ;;
            a|A)
                SHELL_SELECTED=true
                select_shell_type
                SHELL_COMPONENTS="full"
                GIT_SELECTED=true
                select_gitconfig_variant
                VIM_SELECTED=true
                BIN_SELECTED=true
                CLAUDE_SELECTED=true
                CODEX_SELECTED=true
                return
                ;;
            1)
                SHELL_SELECTED=true
                select_shell_type
                select_shell_components
                ;;
            2)
                GIT_SELECTED=true
                select_gitconfig_variant
                ;;
            3)
                VIM_SELECTED=true
                print_success "Vim設定を追加しました"
                ;;
            4)
                BIN_SELECTED=true
                print_success "CLIツールを追加しました"
                ;;
            5)
                CLAUDE_SELECTED=true
                print_success "Claude Code設定を追加しました"
                ;;
            6)
                CODEX_SELECTED=true
                print_success "Codex設定を追加しました"
                ;;
            *)
                print_error "無効な選択です"
                continue
                ;;
        esac

        if [ "$SHELL_SELECTED" = "true" ] && [ "$GIT_SELECTED" = "true" ] && [ "$VIM_SELECTED" = "true" ] && [ "$BIN_SELECTED" = "true" ] && [ "$CLAUDE_SELECTED" = "true" ] && [ "$CODEX_SELECTED" = "true" ]; then
            print_success "全カテゴリが選択されました"
            return
        fi

        printf "\n選択を続けますか? [Y/n]: "
        read -r _cont
        case "$_cont" in
            n|N) return ;;
        esac
    done
}

confirm_installation() {
    _validate_selection || die "ファイルが選択されていません"

    print_header "インストールするファイル"
    echo ""

    [ "$SHELL_SELECTED" = "true" ]  && _preview_shell
    [ "$GIT_SELECTED" = "true" ]    && _preview_git
    [ "$VIM_SELECTED" = "true" ]    && _preview_vim
    [ "$BIN_SELECTED" = "true" ]    && _preview_bin
    [ "$CLAUDE_SELECTED" = "true" ] && _preview_claude
    [ "$CODEX_SELECTED" = "true" ]  && _preview_codex

    _prompt_user_consent
}

_validate_selection() {
    [ "$SHELL_SELECTED" = "true" ] || [ "$GIT_SELECTED" = "true" ] || [ "$VIM_SELECTED" = "true" ] \
        || [ "$BIN_SELECTED" = "true" ] || [ "$CLAUDE_SELECTED" = "true" ] || [ "$CODEX_SELECTED" = "true" ]
}

_preview_shell() {
    case "$SHELL_COMPONENTS" in
        full)
            printf "  ${COLOR_CYAN}シェル設定 - フルセット (${SHELL_TYPE}):${COLOR_RESET}\n"
            case "$SHELL_TYPE" in
                bash)
                    printf "    + config/shell/bash/bashrc -> ~/.bashrc\n"
                    printf "    + config/shell/bash/bash_profile -> ~/.bash_profile\n"
                    ;;
                zsh)
                    printf "    + config/shell/zsh/zshrc -> ~/.zshrc\n"
                    printf "    + config/shell/zsh/zprofile -> ~/.zprofile\n"
                    ;;
                fish)
                    printf "    + config/shell/fish/config.fish -> ~/.config/fish/config.fish\n"
                    ;;
                all)
                    printf "    + config/shell/bash/bashrc -> ~/.bashrc\n"
                    printf "    + config/shell/bash/bash_profile -> ~/.bash_profile\n"
                    printf "    + config/shell/zsh/zshrc -> ~/.zshrc\n"
                    printf "    + config/shell/zsh/zprofile -> ~/.zprofile\n"
                    printf "    + config/shell/fish/config.fish -> ~/.config/fish/config.fish\n"
                    ;;
            esac
            ;;
        append)
            printf "  ${COLOR_CYAN}シェル設定 - 追記モード (${SHELL_TYPE}):${COLOR_RESET}\n"
            printf "    + config/shell/common.sh -> ~/.shell_common\n"
            case "$SHELL_TYPE" in
                bash) printf "    → ~/.bashrc にsource行を自動挿入\n" ;;
                zsh)  printf "    → ~/.zshrc にsource行を自動挿入\n" ;;
                fish) printf "    → ~/.config/fish/config.fish にsource行を自動挿入\n" ;;
                all)  printf "    → ~/.bashrc, ~/.zshrc, ~/.config/fish/config.fish にsource行を自動挿入\n" ;;
            esac
            ;;
    esac
    echo ""
}

_preview_git() {
    printf "  ${COLOR_CYAN}Git設定:${COLOR_RESET}\n"
    printf "    + config/git/.git-completion.bash -> ~/.git-completion.bash\n"
    printf "    + config/git/.git-prompt.sh -> ~/.git-prompt.sh\n"
    printf "    + config/git/.gitattributes -> ~/.config/git/attributes\n"
    if [ -n "$GITCONFIG_VARIANT" ]; then
        printf "    + config/git/.gitconfig.common => ~/.gitconfig.common (copy)\n"
        printf "    + config/git/.gitconfig.%s -> ~/.gitconfig\n" "$GITCONFIG_VARIANT"
        printf "    + config/git/.gitignore.common + .gitignore.%s -> ~/.config/git/ignore\n" "$GITCONFIG_VARIANT"
    fi
    echo ""
}

_preview_vim() {
    printf "  ${COLOR_CYAN}Vim設定:${COLOR_RESET}\n"
    printf "    + config/vim/.vimrc -> ~/.vimrc\n"
    echo ""
}

_preview_bin() {
    printf "  ${COLOR_CYAN}CLIツール:${COLOR_RESET}\n"
    printf "    + bin/* -> ~/.local/bin/*\n"
    echo ""
}

_preview_claude() {
    printf "  ${COLOR_CYAN}Claude Code設定:${COLOR_RESET}\n"
    printf "    + trackedな claude/* と common/* -> 生成・検証 -> ~/.claude/*\n"
    echo ""
}

_preview_codex() {
    printf "  ${COLOR_CYAN}Codex設定:${COLOR_RESET}\n"
    printf "    + trackedな codex/* と common/* -> 生成・検証 -> ~/.codex/*\n"
    printf "    + plugin bundle -> ~/.codex/plugins, ~/.agents/plugins/marketplace.json\n"
    printf "    + codex/config.toml.template -> ~/.codex/config.toml (存在しない場合のみ生成)\n"
    printf "    + codex/*.config.toml -> ~/.codex/*.config.toml (profile)\n"
    printf "    - codex/skills/* は plugin 配布のため install 対象外\n"
    printf "    - codex/hooks.json は作成しない (hooks は config.toml inline TOML)\n"
    echo ""
}

_prompt_user_consent() {
    printf "インストールを実行しますか? [Y/n]: "
    read -r _confirm
    case "$_confirm" in
        n|N) echo "キャンセルしました。"; exit 0 ;;
    esac
}

# ============================================================================
# Top-level Orchestration
# ============================================================================

install_files() {
    print_header "dotfilesをインストール: $DOTFILES_DIR"

    install_shell_config

    if [ "$GIT_SELECTED" = "true" ]; then
        install_git_files
        install_gitconfig
        install_gitignore
    fi

    [ "$VIM_SELECTED" = "true" ] && install_vim_files

    install_bin_files
    install_claude_config
    install_codex_config
}

uninstall_files() {
    print_header "dotfilesをアンインストール"

    [ "$UNINSTALL_SHELL" = "true" ] && uninstall_shell_config
    if [ "$UNINSTALL_GIT" = "true" ]; then
        uninstall_git_files
        uninstall_gitconfig
        uninstall_gitignore
    fi
    [ "$UNINSTALL_VIM" = "true" ]    && uninstall_vim_files
    [ "$UNINSTALL_BIN" = "true" ]    && uninstall_bin_files
    [ "$UNINSTALL_CLAUDE" = "true" ] && uninstall_claude_config
    [ "$UNINSTALL_CODEX" = "true" ]  && uninstall_codex_config
}

show_summary() {
    print_header "結果"
    echo ""

    if [ "$MODE_UNINSTALL" = "true" ]; then
        printf "  削除: ${COLOR_GREEN}%d${COLOR_RESET}\n" "$COUNT_REMOVED"
    else
        printf "  作成: ${COLOR_GREEN}%d${COLOR_RESET}\n" "$COUNT_CREATED"
        printf "  バックアップ: ${COLOR_YELLOW}%d${COLOR_RESET}\n" "$COUNT_BACKUP"
    fi
    printf "  スキップ: ${COLOR_YELLOW}%d${COLOR_RESET}\n" "$COUNT_SKIPPED"

    [ "$COUNT_ERROR" -gt 0 ] && printf "  エラー: ${COLOR_RED}%d${COLOR_RESET}\n" "$COUNT_ERROR"
    echo ""
}

show_help() {
    cat << 'EOF'
dotfiles インストーラー - dotfilesのシンボリックリンクを作成

使い方:
    ./install.sh [オプション]

オプション:
    -h, --help          このヘルプを表示
    -i, --interactive   対話モード(デフォルト)
    -f, --force         確認なしで全ファイルをインストール
    -n, --dry-run       実行内容をプレビュー(変更なし)
    -u, --uninstall     作成したシンボリックリンクを削除

カテゴリ:
    shell   シェル設定 (bash/zsh/fish 選択可能)
    git     Git設定(.gitconfig.work/private, .git-completion.bash等)
    vim     Vim設定(.vimrc)
    bin     CLIツール (git-new-feature等 → ~/.local/bin/)
    claude  Claude Code設定 (claude/, global_* prefix と statusline.settings.json は配置名を変換)
    codex   Codex設定 (codex/)

例:
    ./install.sh              # 対話的にインストール
    ./install.sh -f           # すべてインストール(現在のシェルのみ)
    ./install.sh -n           # インストール内容をプレビュー
    ./install.sh -u           # このリポジトリが管理するシンボリックリンクを削除
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h| --help)        show_help; exit 0 ;;
            -i| --interactive) MODE_INTERACTIVE=true; shift ;;
            -f| --force)       MODE_INTERACTIVE=false; shift ;;
            -n| --dry-run)     MODE_DRY_RUN=true; shift ;;
            -u| --uninstall)   MODE_UNINSTALL=true; shift ;;
            *)                die "不明なオプション: $1\nヘルプは -h で表示" ;;
        esac
    done
}

cleanup() {
    echo ""
    print_info "中断されました"
    exit 130
}

main() {
    trap cleanup INT TERM

    parse_args "$@"
    check_requirements

    [ "$MODE_DRY_RUN" = "true" ] && print_header "ドライランモード - 変更は行われません"

    if [ "$MODE_UNINSTALL" = "true" ]; then
        _run_uninstall_mode
    else
        _run_install_mode
    fi

    _finalize
}

_run_install_mode() {
    if [ "$MODE_INTERACTIVE" = "true" ]; then
        select_files_interactive
        confirm_installation
    else
        _apply_force_mode_defaults
    fi
    generate_ai_assets
    install_files
}

_run_uninstall_mode() {
    if [ "$MODE_INTERACTIVE" = "true" ]; then
        select_uninstall_components
        _confirm_uninstall_unless_dry_run
    else
        _select_all_uninstall_components
    fi
    uninstall_files
}

_apply_force_mode_defaults() {
    SHELL_SELECTED=true
    SHELL_TYPE=$(detect_current_shell)
    SHELL_COMPONENTS="full"
    GIT_SELECTED=true
    VIM_SELECTED=true
    BIN_SELECTED=true
    CLAUDE_SELECTED=true
    CODEX_SELECTED=true

    case "$(detect_platform)" in
        macos) GITCONFIG_VARIANT="private" ;;
        *)     GITCONFIG_VARIANT="work" ;;
    esac

    print_info ".gitconfig: ${GITCONFIG_VARIANT} を自動選択しました"
    print_info "シェル設定: ${SHELL_TYPE} を自動選択しました"
}

_select_all_uninstall_components() {
    UNINSTALL_SHELL=true
    UNINSTALL_GIT=true
    UNINSTALL_VIM=true
    UNINSTALL_BIN=true
    UNINSTALL_CLAUDE=true
    UNINSTALL_CODEX=true
}

_confirm_uninstall_unless_dry_run() {
    [ "$MODE_DRY_RUN" = "true" ] && return 0

    printf "\nアンインストールを実行しますか? [y/N]: "
    read -r _confirm
    case "$_confirm" in
        y|Y) ;;
        *) echo "キャンセルしました。"; exit 0 ;;
    esac
}

_finalize() {
    show_summary
    [ "$COUNT_ERROR" -gt 0 ] && exit 1
    exit 0
}

main "$@"
