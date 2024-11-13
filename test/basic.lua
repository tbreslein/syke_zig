return {
  symlinks = {
    {
      source = "~/.dotfiles/config/alacritty/alacritty.toml",
      target = "~/.config/alacritty/alacritty.toml",
      force = true,
    },
    {
      source = "~/.dotfiles/config/direnv.toml",
      target = "~/.config/direnv/direnv.toml",
    },
  },
}
