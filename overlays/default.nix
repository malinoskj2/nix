{ inputs }:

{
  unstable = final: _prev: {
    unstable = import inputs.nixpkgs-unstable {
      inherit (final.stdenv.hostPlatform) system;
      inherit (final) config;
    };
  };

  # Packages taken from exact nixpkgs revisions. See CLAUDE.md before bumping either input.
  pins =
    _final: prev:
    let
      system = prev.stdenv.hostPlatform.system;
    in
    {
      inherit (inputs.nixpkgs-hyprland.legacyPackages.${system})
        hyprland
        hyprlandPlugins
        xdg-desktop-portal-hyprland
        ;
      inherit (inputs.nixpkgs-firefox.legacyPackages.${system}) firefox;
    };

  htopVimNavigation = _final: prev: {
    htop-vim-navigation =
      assert prev.lib.assertMsg
        (builtins.elem prev.htop.version [
          "3.5.1"
          "3.5.3"
        ])
        "The local htop Vim-navigation patch was written for htop 3.5.1 and 3.5.3; re-check it before updating htop.";
      prev.htop.overrideAttrs (old: {
        pname = "htop-vim-navigation";
        patches = (old.patches or [ ]) ++ [
          (builtins.toFile "htop-vim-navigation.patch" ''
            diff --git a/ScreenManager.c b/ScreenManager.c
            --- a/ScreenManager.c
            +++ b/ScreenManager.c
            @@ -330,6 +330,14 @@ void ScreenManager_run(ScreenManager* this, Panel** lastFocus, int* lastKey, con
                   continue;
                }

            +      /* Use Vim navigation outside text-entry modes. */
            +      if (!panelFocus->cursorOn) {
            +         if (ch == 'h') ch = KEY_LEFT;
            +         if (ch == 'j') ch = KEY_DOWN;
            +         if (ch == 'k') ch = KEY_UP;
            +         if (ch == 'l') ch = KEY_RIGHT;
            +      }
            +
                switch (ch) {
                   case KEY_ALT('H'): ch = KEY_LEFT; break;
                   case KEY_ALT('J'): ch = KEY_DOWN; break;
          '')
        ];
        meta = old.meta // {
          description = "${old.meta.description}, with local h/j/k/l navigation";
        };
      });
  };

  modifications = final: prev: {
    hyprlandPlugins = prev.hyprlandPlugins // {
      # The patches hook and poke Hyprland internals, so any Hyprland change needs them re-checked.
      hyprfocus =
        assert prev.lib.assertMsg (final.hyprland.version == "0.56.2")
          "hyprfocus patches were written against Hyprland 0.56.2 but got ${final.hyprland.version}; re-check patches/hyprfocus/*.patch before bumping the nixpkgs-hyprland pin.";
        prev.hyprlandPlugins.hyprfocus.overrideAttrs (old: {
          version = "${old.version}-patched";
          __intentionallyOverridingVersion = true;
          patches = [
            # Adds plugin:hyprfocus:class so the animation can be limited to specific windows,
            # and skips newly mapped windows.
            ../patches/hyprfocus/class-filter.patch
            # Lets *_focus_animation take a list like "flash,shrink" to run both at once.
            ../patches/hyprfocus/combined-modes.patch
            # Makes shrink a render-time scale instead of resizing the client.
            ../patches/hyprfocus/render-shrink.patch
          ];

          meta = old.meta // {
            description = "Hyprland focus animation plugin with local class filter, combined modes, and render-only shrink";
          };
        });
    };
  };
}
