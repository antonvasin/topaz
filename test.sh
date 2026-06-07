#!/usr/bin/env bash
out_dir="topaz-out"

rm -rf $out_dir && zig build run -- render test --out=$out_dir && cat "$out_dir/hello.html" && zig build run -- query dolores
