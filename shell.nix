with import <nixpkgs> {};

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zls
    zig
    gdb
    valgrind
    # For linter script on push hook
    python3
    wabt
    cmake
    clang-tools
    nodePackages.typescript-language-server
    vscode-langservers-extracted
    nodePackages.prettier
    nodePackages.jshint
  ];
}

