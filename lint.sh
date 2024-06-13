#!/usr/bin/env bash

set -ex

zig build --summary all
zig fmt build.zig --check
zig fmt src --check
zig fmt tools --check
prettier -c src/
jshint src/

echo "Success"
