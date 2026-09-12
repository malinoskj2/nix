# Focus animation for Hyprland, sourced from hyprland.conf via /etc/hypr/hyprfocus.conf
{ pkgs, ... }:

{
  environment.etc."hypr/hyprfocus.conf".text = ''
    plugin = ${pkgs.hyprfocus}/lib/libhyprfocus.so

    plugin {
      hyprfocus {
        class = ^(firefox|dev\.zed\.Zed)$
        keyboard_focus_animation = shrink
        mouse_focus_animation = shrink
        shrink_percentage = 0.99
      }
    }

    # Quick dip in, then ease back out.
    bezier = hyprfocusDip, 0.25, 1, 0.5, 1
    # The hyprfocusIn/Out leaves only exist once the plugin is loaded, which happens after the
    # first config parse, so setting them inline errors at login. `exec` runs after each parse.
    exec = hyprctl --batch "keyword animation hyprfocusIn, 1, 1.5, hyprfocusDip ; keyword animation hyprfocusOut, 1, 4, hyprfocusDip"
  '';
}
