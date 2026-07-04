# openssl zig package

This is openssl ported to the Zig Build System.

## Vendored into zoxy (local changes)

Vendored from [allyourcodebase/openssl] commit `6b318b4` (MIT). The OpenSSL
*sources* are still fetched by content hash via this package's build.zig.zon;
only the build recipe lives here. Local fixes on top of upstream, all of one
kind — the upstream recipe compiled both a C implementation and the x86_64
assembly that replaces it, which classic linkers tolerate through lazy archive
extraction but Zig's strict linker rejects as duplicate symbol definitions:

- commented out C fallbacks superseded by x86_64 asm: `aes/aes_cbc.c`,
  `bn/bn_asm.c` (x86_64 uses `bn/asm/x86_64-gcc.c`), `camellia/camellia.c`,
  `camellia/cmll_cbc.c`, `chacha/chacha_enc.c`, `rc4/rc4_enc.c`,
  `rc4/rc4_skey.c`, `sha/keccak1600.c`, `whrlpool/wp_block.c`;
- commented out `des/ncbc_enc.c` (belongs to the x86 *asm* DES variant only;
  the compiled `des/des_enc.c` already defines `DES_ncbc_encrypt`);
- commented out `loongarchcap.c` (LoongArch-only; its `OPENSSL_cpuid_setup`
  collided with `x86_64cpuid.s`);
- removed a doubled `ec/x25519-x86_64.s` entry.

[allyourcodebase/openssl]: https://github.com/allyourcodebase/openssl

## Status

I was able to use this to build [CPython](https://github.com/thejoshwolfe/cpython) for x86_64-linux.

Adding support for other operating systems and CPU architectures is straightforward and will
require fiddling with the build script to take into account the target.

## Zig version compatibility

- `0.16.x`
- `0.15.x`
- `0.14.x`

## Anti-Endorsement

I do not endorse openssl. I think it is a pile of trash. My motivation for this
project is because it is a dependency of CPython, which is a dependency of the
most active YouTube downloader, [ytdlp](https://github.com/yt-dlp/yt-dlp).
