{ htop, lib }:

let
  supportedVersions = [
    "3.5.1"
    "3.5.3"
  ];
in
assert lib.assertMsg (lib.elem htop.version supportedVersions) (
  "vim-navigation.patch was written for htop "
  + "${lib.concatStringsSep ", " supportedVersions}, not ${htop.version}; "
  + "re-check it and update this assertion."
);
htop.overrideAttrs (old: {
  pname = "htop-vim-navigation";

  patches = (old.patches or [ ]) ++ [
    ./vim-navigation.patch
  ];

  meta = old.meta // {
    description = "${old.meta.description}, with h/j/k/l navigation";
  };
})
