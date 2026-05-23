# Readme

For power, performance, area (PPA) driven development, code is written in DSLX (part of google's XLS SDK, see below), compiled to verilog, synthesized by librelane, and then PPA metrics are collected.

## Enter the environment with your copilot

```
cd /PATH/TO/YOUR/LIBRELANE
nix-shell
librelane --smoke-test
cd /PATH/TO/PPA-STUDY
cd ./xls-bin
./interpreter_main --version
cd ..
claude
```

## Install Tools

### Librelane

Use nix-based librelane installation following
* https://librelane.readthedocs.io/en/latest/installation/nix_installation/installation_linux.html

### Google's XLS: Accelerated HW Synthesis

Documentation can be found at
* https://google.github.io/
* https://github.com/google/xls/

Install the tools statically compiled from https://github.com/gbsha/xls-bin/ by
```
mkdir -p ./xls-bin && cd ./xls-bin

curl -L -O https://github.com/gbsha/xls-bin/releases/download/v1.0-xls-oracle8/xls-oracle8-binaries.tar.gz
tar -xzf xls-oracle8-binaries.tar.gz
chmod +x *
```

