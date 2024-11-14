local user = "tommy"
local home = "/Users/" .. user

return {
  symlinks = {
    {
      source = home .. "/.dotfiles/config/alacritty/alacritty.toml",
      target = home .. "/.config/alacritty/alacritty.toml",
    },
    {
      source = home .. "/.dotfiles/config/direnv.toml",
      target = home .. "/.config/direnv/direnv.toml",
    },
  },
}
