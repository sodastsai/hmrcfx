#!/usr/bin/env bash
set -euo pipefail

log()  { echo "[setup] $*"; }
fail() { echo "[setup] ERROR: $*" >&2; }

# Claude Persistence
log "--- claude persistence ---"
if sudo chown -R codespace:codespace /home/codespace/.claude; then
  log "chown /home/codespace/.claude OK"
else
  fail "chown /home/codespace/.claude failed"
  exit 1
fi

# oh-my-zsh update
log "--- oh-my-zsh ---"

log "installing fzf"
git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
~/.fzf/install --no-update-rc --key-bindings --completion

log "installing zsh-autosuggestions"
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

log "installing zsh-syntax-highlighting"
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

if [ ! -d "$HOME/.oh-my-zsh" ]; then
  log "installing oh-my-zsh"
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
else
  log "upgrading oh-my-zsh"
  "$HOME/.oh-my-zsh/tools/upgrade.sh"
fi

log "--- done ---"
