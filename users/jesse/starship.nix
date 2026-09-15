{
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      add_newline = false;

      aws.disabled = true;
      battery.disabled = true;
      cmake.disabled = true;
      cobol.disabled = true;
      cmd_duration.disabled = true;
      conda.disabled = true;
      crystal.disabled = true;
      dart.disabled = true;
      deno.disabled = true;
      directory.disabled = true;
      docker_context.disabled = true;
      dotnet.disabled = true;
      elixir.disabled = true;
      elm.disabled = true;
      env_var.disabled = true;
      erlang.disabled = true;
      fill.disabled = true;
      gcloud.disabled = true;

      git_branch = {
        symbol = "➜ ";
        format = "[$symbol$branch]($style) ";
        truncation_length = 7;
        truncation_symbol = "";
      };

      git_commit.disabled = true;
      git_state.disabled = true;
      git_metrics.disabled = true;

      git_status = {
        disabled = false;
        style = "bold red";
        untracked = "!";
        modified = "!";
        staged = "!";
        stashed = "";
        ahead = "";
        behind = "";
        diverged = "";
      };

      golang.disabled = true;
      helm.disabled = true;
      hostname.disabled = true;
      java.disabled = true;
      jobs.disabled = true;
      julia.disabled = true;
      kotlin.disabled = true;
      kubernetes.disabled = true;
      line_break.disabled = true;
      lua.disabled = true;
      memory_usage.disabled = true;
      hg_branch.disabled = true;
      nim.disabled = true;
      nix_shell.disabled = true;
      nodejs.disabled = true;
      ocaml.disabled = true;
      openstack.disabled = true;
      package.disabled = true;
      perl.disabled = true;
      php.disabled = true;
      pulumi.disabled = true;
      purescript.disabled = true;
      python.disabled = true;
      rlang.disabled = true;
      red.disabled = true;
      ruby.disabled = true;
      rust.disabled = true;
      scala.disabled = true;
      shell.disabled = true;
      shlvl.disabled = true;
      singularity.disabled = true;
      status.disabled = true;
      swift.disabled = true;
      terraform.disabled = true;
      time.disabled = true;

      username = {
        show_always = true;
        format = "[$user ]($style)";
        style_user = "bold normal";
      };

      vagrant.disabled = true;
      vlang.disabled = true;
      vcsh.disabled = true;
      zig.disabled = true;

      character = {
        success_symbol = "[➜](bold green)";
        error_symbol = "[➜](bold red)";
      };
    };
  };
}
