# Hyprland Desktop Behavior Checklist

Use this checklist on the `home` machine after deploying the migration. The
expected final stack is Hyprland 0.56.2 with Noctalia; Waybar, Hyprpaper, and
Hyprlock are not active desktop components.

## Deploy without switching permanently

- [ ] Build only `home` from the repository root:

  ```sh
  nix build .#nixosConfigurations.home.config.system.build.toplevel --impure
  ```

- [ ] Test the result without making it the boot default:

  ```sh
  sudo nixos-rebuild test --impure --flake .#home
  ```

- [ ] Log out and back into Hyprland. Confirm the session reaches a usable
  desktop without an error overlay.
- [ ] Confirm the expected version and a clean configuration:

  ```sh
  hyprctl version
  hyprctl configerrors
  hyprctl plugins list
  ```

  `hyprctl version` should report 0.56.2, `configerrors` should be empty, and
  both `hyprbars` and the patched `hyprfocus` should be listed.

## Declarative ownership

- [ ] Confirm the active entry point and Noctalia files resolve into
  `/nix/store`, not `/home/jesse/env`:

  ```sh
  readlink -f ~/.config/hypr/hyprland.lua
  readlink -f ~/.config/hypr/actions.lua
  readlink -f ~/.config/noctalia/config.toml
  readlink -f ~/.local/share/noctalia/plugins/control-button
  readlink -f ~/.local/share/noctalia/plugins/hypr-workspaces
  ```

- [ ] Confirm `~/.config/hypr/hyprland.conf` is absent so Lua is the single
  Hyprland entry point.
- [ ] Confirm the migrated module has no old dotfiles-repository dependency:

  ```sh
  rg -n '/home/jesse/env|~/env' users/jesse/desktop-home
  ```

  The command should print nothing. Matches in unrelated shared X11 dotfiles
  under `hosts/home/x.nix` are outside this migration.

## Displays and workspaces

- [ ] DP-1 is portrait, 1920x1080 at 144 Hz, transformed clockwise and placed
  at `0x0`.
- [ ] DP-2 is landscape, 1920x1080 at 360 Hz and placed at `1080x0`.
- [ ] Named workspace `side` is persistent and starts on DP-1.
- [ ] Workspaces 1 through 5 are persistent on DP-2, with workspace 1 the
  default.
- [ ] On DP-2, `Super+O` moves right through 1-5 and wraps 5 to 1;
  `Super+Y` moves left and wraps 1 to 5.
- [ ] `Super+Shift+O` and `Super+Shift+Y` move the focused window through the
  same wrapped workspace range.
- [ ] Those four wrapped-workspace bindings do nothing while DP-1 is focused.
- [ ] The custom Noctalia workspace pills show only positive-numbered
  workspaces on the bar's monitor, update when windows/workspaces change, and
  switch workspace when clicked. Scrolling them moves to the adjacent existing
  workspace.

## Window management and rules

- [ ] `Super+H/J/K/L` moves focus left/down/up/right.
- [ ] `Super+Shift+H/J/K/L` swaps the focused tiled window in those directions.
- [ ] `Super+Alt+H/L` changes width and `Super+Alt+K/J` changes height with the
  same incremental behavior as before migration.
- [ ] `Super` plus left-mouse drag moves a window; `Super` plus right-mouse drag
  resizes it.
- [ ] `Super+V` makes a tiled window floating, sizes it to about 70% by 65% of
  its monitor, and centers it. Pressing it again returns the window to tiling.
- [ ] Maximize requests are suppressed.
- [ ] Alacritty, Firefox, Zed, Dolphin, and DataGrip retain their border rules;
  Alacritty retains its focused/unfocused opacity behavior.
- [ ] GTK portal dialogs float. Noctalia application windows float at 1080x920.
- [ ] Hyprbars appears only on Alacritty windows, retains its compact styling,
  and double-clicking it toggles fullscreen.
- [ ] Moving keyboard or mouse focus between established windows produces the
  subtle hyprfocus shrink without changing the application's layout. Newly
  mapped windows should not receive the focus shrink during their opening
  animation.

## Launch and Noctalia controls

- [ ] `Super+Return`, `Super+F`, `Super+C`, `Super+D`, and `Super+E` launch
  Alacritty, Firefox, Chrome, DataGrip, and Zed respectively.
- [ ] `Super+Shift+C` launches the dedicated Chrome WebGPU/XWayland profile.
- [ ] `Super+Q` closes the focused window.
- [ ] `Super+Space` toggles the launcher, `Super+S` toggles control center, and
  `Super+,` toggles settings.
- [ ] Volume up, volume down, and mute media keys work, including while locked.
- [ ] `Super+P` opens region capture; the result is copied to the clipboard and
  saved beneath `/tmp/screenshot`.
- [ ] The Noctalia bar is enabled only on DP-2, uses the glass appearance, and
  contains the custom workspace widget, active-window title, media/status
  area, and clock.
- [ ] The snowflake control button is visible near the top of DP-2, animates on
  hover, and opens control center when clicked.

## Lock, idle, and lifecycle behavior

- [ ] `Super+Escape` opens the Noctalia lock screen and a valid password
  unlocks it.
- [ ] The expected login widgets appear on both monitors; DP-2 also shows the
  avatar and user label.
- [ ] At idle, the session locks after 30 minutes, turns displays off one minute
  after locking, and suspends after two hours total idle time.
- [ ] Manual suspend/resume returns to a working lock screen and then a usable
  desktop.
- [ ] A compositor reload leaves Noctalia, both plugins, bindings, hyprbars,
  hyprfocus, and wallpaper control operational:

  ```sh
  hyprctl reload
  hyprctl configerrors
  hyprctl plugins list
  ```

- [ ] A full reboot reaches the same working desktop.

## Wallpaper behavior

- [ ] At login, each assigned output receives a random video from
  `~/.wallpapers/video`; outputs use distinct videos when enough candidates
  exist and do not immediately repeat their own previous video.
- [ ] The user service is active and supervised:

  ```sh
  systemctl --user status wallpaper-autopause.service
  journalctl --user -u wallpaper-autopause.service -b
  ```

- [ ] A monitor's video plays when its visible workspace is empty and pauses as
  soon as that workspace has a normal or special-workspace window.
- [ ] Moving, opening, closing, or floating windows and changing workspaces
  updates pause state promptly on each monitor.
- [ ] All wallpaper videos pause while the session is locked and resume only on
  empty visible workspaces after unlock.
- [ ] Restarting Noctalia or its mpvpaper instance is detected and the correct
  pause state is re-applied.

## Legacy-component and cleanup gate

- [ ] No legacy desktop process is running:

  ```sh
  pgrep -a -f '(^|/)(waybar|hyprpaper|hyprlock)( |$)' || true
  ```

- [ ] After login, reload, lock/unlock, suspend/resume, and reboot have all
  passed, remove the now-unused migrated Hyprland, Noctalia, plugin, and helper
  copies from `/home/jesse/env`. Keep unrelated dotfiles there.
- [ ] Repeat the ownership checks above and confirm the desktop still starts.

Do not permanently switch the system or delete the rollback copies until every
applicable item above has passed.
