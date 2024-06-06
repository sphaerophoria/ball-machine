#!/usr/bin/env bash

set -ex

zig build --summary all
zig fmt build.zig --check
zig fmt src --check
prettier -c src

echo "Success"
