{
  coreutils,
  gh,
  git,
  gnugrep,
  lib,
  symlinkJoin,
  unstable,
  writeShellApplication,
}:

let
  inherit (unstable) betterleaks;

  wrap =
    {
      package,
      bin,
      script,
      replacements ? { },
    }:
    let
      vars = {
        ${bin} = "${package}/bin/${bin}";
      }
      // replacements;
      wrapper = writeShellApplication {
        name = bin;
        text = lib.replaceStrings (map (name: "@${name}@") (lib.attrNames vars)) (lib.attrValues vars) (
          builtins.readFile script
        );
      };
    in
    symlinkJoin {
      inherit (package) version;
      pname = "${package.pname}-push-gate";
      paths = [ package ];
      postBuild = ''
        rm "$out/bin/${bin}"
        ln -s ${lib.getExe wrapper} "$out/bin/${bin}"
      '';
      passthru.unwrapped = package;
      meta = package.meta // {
        mainProgram = bin;
      };
    };
in
writeShellApplication {
  name = "betterleaks-pre-push";
  runtimeInputs = [
    betterleaks
    coreutils
    git
  ];
  text = builtins.readFile ./pre-push.sh;

  passthru = {
    inherit betterleaks;
    git = wrap {
      package = git;
      bin = "git";
      script = ./git.sh;
    };
    gh = wrap {
      package = gh;
      bin = "gh";
      script = ./gh.sh;
      replacements.grep = lib.getExe gnugrep;
    };
  };

  meta.description = "Git pre-push hook that refuses commits Betterleaks flags as secrets";
}
