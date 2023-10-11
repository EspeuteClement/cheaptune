# Cheaptune

Work in progress software synthetiser and player for retro sounds and musics.

## Building / running

`zig build run`

## Notes

Only the windows target is supported at the moment (just for the midi input in main).

Uses raylib at the moment for rendering the main window.

debug assembly :
```
zig build-obj --name output -femit-asm=output.s -O ReleaseFast src/bench.zig
```