# AddingSpace
Space exploration game

## Building
```sh
atlas install
nim build
```
With cross-compilation support (requires installed `zig`):
```sh
atlas install --feature=forge
nim build target=x86_64-linux-gnu # or x86_64-windows-gnu etc.
```
