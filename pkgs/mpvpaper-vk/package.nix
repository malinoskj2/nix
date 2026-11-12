{
  libplacebo,
  mpv-unwrapped,
  mpvpaper,
  vulkan-headers,
  vulkan-loader,
}:
let
  # A private libmpv, so the system mpv stays unpatched.
  mpv = mpv-unwrapped.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./libmpv-vulkan.patch ];
  });
in
(mpvpaper.override { inherit mpv; }).overrideAttrs (old: {
  pname = "mpvpaper-vk";

  patches = (old.patches or [ ]) ++ [ ./mpvpaper-vulkan.patch ];

  buildInputs = old.buildInputs ++ [
    libplacebo
    vulkan-headers
    vulkan-loader
  ];

  preInstall = ''
    mv ../mpvpaper.man ../mpvpaper-vk.1
  '';

  postInstall = ''
    installManPage ../mpvpaper-vk.1
  '';

  meta = old.meta // {
    description = "mpvpaper drawing through a Vulkan libmpv render API";
    mainProgram = "mpvpaper-vk";
  };
})
