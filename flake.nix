{
  description = "Dynamic BPF-based system-wide tracing tool";

  inputs = {
    nixpkgs.url = "nixpkgs/24.05";
    flake-utils.url = "github:numtide/flake-utils";
    src = {
      url = "github:oracle/dtrace-utils/devel";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        bpfGcc = with pkgs; writeShellScriptBin "bpf-unknown-none-gcc" ''
          if [[ "$*" == *".S"* ]]; then
            exec ${clang}/bin/clang \
              -target bpf \
              -D__KERNEL__ \
              -D__BPF_TRACING__ \
              -I${linuxHeaders}/include \
              -Wno-unused-command-line-argument \
              -integrated-as \
              -x assembler-with-cpp \
              -Xclang -mllvm \
              -Xclang --x86-asm-syntax=att \
              -Xclang -mllvm \
              -Xclang --asm-macro-max-nesting-depth=50 \
              -mrelax-all \
              "$@"
          else
            exec ${clang}/bin/clang \
              -target bpf \
              -D__KERNEL__ \
              -D__BPF_TRACING__ \
              -I${linuxHeaders}/include \
              -Wno-unused-command-line-argument \
              -O2 \
              -Wno-unused-value \
              -Wno-pointer-sign \
              -Wno-compare-distinct-pointer-types \
              -Wno-gnu-variable-sized-type-not-at-end \
              -Wno-address-of-packed-member \
              -Wno-tautological-compare \
              -Wno-unknown-warning-option \
              -fno-stack-protector \
              "$@"
          fi
        '';
        bpfLd = with pkgs; writeShellScriptBin "bpf-unknown-none-ld" ''
          exec ${lld}/bin/lld "$@"
        '';
      in
      {
        packages.default = pkgs.stdenv.mkDerivation rec {
          # Copied from https://gitweb.gentoo.org/repo/gentoo.git/tree/dev-debug/dtrace/dtrace-2.0.1.1-r2.ebuild
          inherit src;
          name = "dtrace";

          nativeBuildInputs = with pkgs; [
            clang
            pkg-config
            bison
            flex
            gawk
            bpftools

            bpfGcc
            bpfLd
          ];

          buildInputs = with pkgs; [
            elfutils
            libbpf
            libpfm
            wireshark
            libpcap
            fuse3
            binutils-unwrapped
            zlib
            systemd
            valgrind
            pkgsi686Linux.glibc
            gawk
          ];

          patchPhase = ''
            patchShebangs ./configure
            patchShebangs ./libproc/mkoffsets.sh
            patchShebangs ./include/mkHelpers

            sed -i 's;/usr/include/bpf;${pkgs.libbpf}/include/bpf;' ./include/Build
          '';

          configureFlags = [
            "--user-uid=1000"
            "HAVE_BPFV3=yes"
            "HAVE_LIBCTF=yes"
            "HAVE_LIBSYSTEMD=yes"
          ];

          hardeningDisable = [ "fortify" ]; # https://github.com/oracle/dtrace-utils/issues/78

          enableParallelBuilding = false;

          # Handle stripping specially for BPF libs
          dontStrip = true;
          postFixup = ''
            # Strip everything except BPF libs
            find $out -type f -executable -not -path "*/lib/*" -exec strip {} +
          '';

          meta = with pkgs.lib; {
            description = "Dynamic BPF-based system-wide tracing tool";
            homepage = "https://github.com/oracle/dtrace-utils";
            # license = licenses.upl10;
            platforms = platforms.linux;
            maintainers = [ "timothyklim" ];
          };
        };

        nixosModules.dtrace = { config, lib, pkgs, ... }: with lib; {
          options.programs.dtrace = {
            enable = mkEnableOption "DTrace service";
          };

          config = mkIf config.programs.dtrace.enable {
            boot = {
              kernel.features.debug = true;
              kernelModules = [
                "bpf"
                "cuse"
              ];
            };

            system.requiredKernelConfig = map config.lib.kernelConfig.isEnabled [
              "BPF"
              "DEBUG_INFO_BTF"
              "KALLSYMS_ALL"
              "CUSE"
              "TRACING"
              "PROBES"
              "UPROBE_EVENTS"
              "TRACE"
              "FTRACE_SYSCALLS"
              "DYNAMIC_FTRACE"
              "FUNCTION_TRACER"
              "FPROBE"
            ];

            systemd.services.dtprobed = {
              description = "DTrace Probe Daemon";
              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];
              serviceConfig = {
                ExecStart = "${self.packages.${system}.default}/sbin/dtprobed";
                Type = "simple";
                Restart = "on-failure";
              };
            };

            environment.systemPackages = [ self.packages.${system}.default ];
          };
        };
        formatter = nixpkgs.legacyPackages.${system}.nixpkgs-fmt;
      });
}
