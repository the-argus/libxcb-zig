{
  description = "libxcb built with zig";

  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
  in {
    devShell.${system} =
      pkgs.mkShell.override
      {
        # use gcc for libc headers in intellisense
        stdenv = pkgs.gccStdenv;
      }
      {
        packages = with pkgs; [
          zig_0_11
          python3Minimal
          xorg.xcbproto
          pkg-config
          gdb
        ];
      };
  };
}
