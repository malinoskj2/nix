{
  bash,
  coreutils,
  fetchPypi,
  ghidra,
  lib,
  openjdk21,
  python3Packages,
  util-linux,
}:

let
  ghidrecomp = python3Packages.buildPythonPackage rec {
    pname = "ghidrecomp";
    version = "0.5.9";
    pyproject = true;

    src = fetchPypi {
      inherit pname version;
      hash = "sha256-ocluLUic2qMREO7kXWum8l3VZ/parj/WtQ9JgOood6I=";
    };

    build-system = [ python3Packages.setuptools ];
    dependencies = [ python3Packages.pyghidra ];

    pythonImportsCheck = [ "ghidrecomp" ];
  };
in
python3Packages.buildPythonApplication rec {
  pname = "pyghidra-mcp";
  version = "0.2.7";
  pyproject = true;

  src = fetchPypi {
    pname = "pyghidra_mcp";
    inherit version;
    hash = "sha256-ieR/OWAlZmfG+Y71xj5qWl6b5GdxNUeUfcksLx+UAYU=";
  };

  patches = [ ./stdio-stdout.patch ];

  build-system = [ python3Packages.hatchling ];

  dependencies =
    with python3Packages;
    [
      chromadb
      click
      click-option-group
      ghidrecomp
      mcp
      pyghidra
    ]
    ++ mcp.optional-dependencies.cli;

  makeWrapperArgs = [
    "--set-default GHIDRA_INSTALL_DIR ${ghidra}/lib/ghidra"
    "--set-default JAVA_HOME ${openjdk21}"
    "--prefix PATH : ${lib.makeBinPath [ openjdk21 ]}"
  ];

  buildInputs = [ bash ];

  postInstall = ''
    install -Dm755 ${./ghidra-mcp.sh} $out/bin/ghidra-mcp
    substituteInPlace $out/bin/ghidra-mcp --replace-fail @pyghidra-mcp@ $out/bin/pyghidra-mcp
    wrapProgram $out/bin/ghidra-mcp --prefix PATH : ${
      lib.makeBinPath [
        coreutils
        util-linux
      ]
    }
  '';

  pythonImportsCheck = [ "pyghidra_mcp" ];

  meta = {
    description = "Headless Ghidra MCP server, with a per-directory stdio launcher for agents";
    homepage = "https://github.com/clearbluejar/pyghidra-mcp";
    license = lib.licenses.asl20;
    mainProgram = "ghidra-mcp";
  };
}
