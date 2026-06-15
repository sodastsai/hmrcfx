#!/usr/bin/env bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/sodastsai/dotfiles /tmp/dotfiles && git -C /tmp/dotfiles sparse-checkout set devenv/.devcontainer && cp -rn /tmp/dotfiles/devenv/.devcontainer/. .devcontainer/ && rm -rf /tmp/dotfiles
