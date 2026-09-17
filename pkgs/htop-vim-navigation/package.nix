{ htop, lib }:

assert lib.assertMsg (builtins.elem htop.version [
  "3.5.1"
  "3.5.3"
]) "vim-navigation.patch was written for htop 3.5.1 and 3.5.3; re-check it before updating htop.";
htop.overrideAttrs (old: {
  pname = "htop-vim-navigation";
  patches = (old.patches or [ ]) ++ [
    # h/j/k/l move like the arrow keys whenever no text field has focus.
    ./vim-navigation.patch
  ];
  meta = old.meta // {
    description = "${old.meta.description}, with h/j/k/l navigation";
  };
})
