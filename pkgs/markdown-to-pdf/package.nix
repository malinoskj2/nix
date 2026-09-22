{
  fetchFromGitHub,
  librsvg,
  mermaid-cli,
  pandoc,
  texlive,
  writeShellApplication,
}:

let
  # Pinned before the 3.5.0 sourcesanspro -> sourcesans migration; nixpkgs' texlive
  # doesn't package sourcesans yet, and only sourcesanspro/sourcecodepro exist there.
  eisvogel = fetchFromGitHub {
    owner = "Wandmalfarbe";
    repo = "pandoc-latex-template";
    rev = "v3.4.0";
    hash = "sha256-0tz/I4eEVJYFBHWvxRPg5ZRsPERGCGyTqItphp3wies=";
  };
in
writeShellApplication {
  name = "markdown-to-pdf";
  runtimeInputs = [
    librsvg
    mermaid-cli
    pandoc
    texlive.combined.scheme-full
  ];
  text = ''
    export MARKDOWN_TO_PDF_TEMPLATE=${eisvogel}/template-multi-file/eisvogel.latex
  ''
  + builtins.readFile ./markdown-to-pdf.sh;
  meta.description = "Render a highly technical markdown file (code, tables, Mermaid diagrams) to a typeset PDF";
}
