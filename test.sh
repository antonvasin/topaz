#!/usr/bin/env bash
out_dir="topaz-out"

rm -rf $out_dir && zig build run -- test && cat "$out_dir/comprehensive.html"
