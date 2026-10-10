# WebAssembly/WASM Wrapper

## Build

1. [Install Emscripten](https://kripken.github.io/emscripten-site/docs/getting_started/) if not done already.
2. In an empty build folder, invoke `emcmake cmake <path to zxing-cpp.git/wrappers/wasm>`.
3. Invoke `cmake --build .` to create `zxing.js` and `zxing.wasm` (and `_reader`/`_writer` versions).
4. To see how to include these into a working HTML page, have a look at the [reader](demo_reader.html), [writer](demo_writer.html) and [cam reader](demo_cam_reader.html) demos.
5. To quickly test your build, copy those demo files into your build directory and run e.g. `emrun --serve_after_close demo_reader.html`.
6. To run the round-trip smoke test under node, configure a separate build with `-DZXING_EMSCRIPTEN_ENVIRONMENT=node` and run `node test_roundtrip.js <build folder>/zxing.js`.

You can also download the latest build output from the continuous integration system from the [Actions](https://github.com/zxing-cpp/zxing-cpp/actions) tab. Look for 'wasm-artifacts'. Also check out the [live demos](https://github.com/zxing-cpp/zxing-cpp#web-demos).

## Reducing the Download Size

The default `zxing_reader.wasm` supports all formats and is about 880kB (310kB brotli compressed). These CMake options make it smaller:

| Option | Effect |
|--------|--------|
| `-DZXING_WASM_IMAGE_DECODING=OFF` | Drops `readBarcode(s)FromImage` and the bundled stb_image PNG/JPEG decoder. Use this if you only pass raw pixels (e.g. camera frames via `readBarcode(s)FromPixmap`). Browsers can decode image files themselves via a canvas. |
| `-DZXING_ENABLE_UNICODE=OFF` | Drops the multi-byte character set tables (Shift_JIS, GB2312/GBK/GB18030, Big5, EUC-KR, ...) and the less common single-byte code pages. ASCII, UTF-8, ISO-8859-1 (the default of e.g. DataMatrix and MaxiCode) and binary content still decode correctly; text in the dropped character sets comes back empty (`bytes` is still available). |
| `-DZXING_WASM_EXCEPTIONS=wasm` | Uses native WebAssembly exceptions instead of emulating them via JavaScript. Smaller and faster, but needs Chrome 95, Firefox 100, Safari 15.2 or newer. |
| `-DZXING_ENABLE_<FORMAT>=OFF` | Drops support for a format family: `1D`, `AZTEC`, `DATAMATRIX`, `MAXICODE`, `PDF417`, `QRCODE`. |
| `-DZXING_WASM_LTO=OFF` | Disables link time optimization (on by default, see below). |
| `-DCMAKE_BUILD_TYPE=MinSizeRel` | Optimizes for size (`-Os`) instead of speed (`-O3`). |
| `-DCMAKE_EXE_LINKER_FLAGS=-sMALLOC=emmalloc` | Uses emscripten's smaller (but simpler) memory allocator. |

Measured with emsdk 6.0.11 for `zxing_reader.wasm`. Each row adds to the one above, except where noted. The runtime is the mean time per 720p camera-like frame with all formats enabled (node 24 on x86, so expect phones to be slower); differences below ~5% are within the measurement noise.

| Configuration | raw | brotli | runtime |
|---------------|----:|-------:|--------:|
| default (`-O3`, LTO, all formats) | 884kB | 308kB | 6.3ms |
| + `ZXING_WASM_IMAGE_DECODING=OFF` | 799kB | 284kB | 6.2ms |
| + `ZXING_ENABLE_UNICODE=OFF` | 687kB | 206kB | 6.6ms |
| + `ZXING_WASM_EXCEPTIONS=wasm` | 628kB | 200kB | 5.9ms |
| + `-sMALLOC=emmalloc` | 622kB | 198kB | 6.1ms |
| + `ZXING_ENABLE_AZTEC=OFF` | 592kB | 188kB | 6.0ms |
| emmalloc row + `MinSizeRel` (`-Os`) | 478kB | 165kB | 6.9ms |
| emmalloc row, DataMatrix only (other formats off) | 226kB | 73kB | |

Without LTO, the default build is ~25kB larger and takes about 7.8ms per frame.

## Alternative Wrapper Project

There is an alternative (external) wrapper project called [zxing-wasm](https://github.com/Sec-ant/zxing-wasm). It is written in TypeScript, has a more feature complete interface closer to the C++ API, spares you from dealing with WASM intricacies and is provided as a fully fledged ES module on [npmjs](https://www.npmjs.com/package/zxing-wasm).

## Performance

It turns out that compiling the library with the `-Os` (`MinSizeRel`) flag causes a noticeable performance penalty. Here are some measurements from the demo_cam_reader (performed on Chromium 109 running on a Core i9-9980HK):

|         | `-Os` | `-Os -flto` | `-O3`  | `-O3 -flto` | _Build system_ |
|---------|-------|-------------|--------|-------------|-|
| size    | 790kB | 950kb       | 940kb  | 1000kB      | _All_               |
| runtime | 320ms | 30ms        | 8ms    | 8ms         | C++17, emsdk 3.1.9  |
| runtime | 13ms  | 30ms        | 8ms    | 8ms         | C++17, emsdk 3.1.31 |
| runtime | 46ms  | 46ms        | 11ms   | 11ms        | C++20, emsdk 3.1.31 |

Conclusions:
 * saving 15% of download size for the price of a 2x-4x slowdown seems like a hard sale (let alone the 40x one)...
 * building in C++-20 mode brings position independent DataMatrix detection but costs 35% more time
 * link time optimization (`-flto`) is not worth it and potentially even counter productive (this has changed with newer emscripten versions: with emsdk 6.0.11, `-flto` makes the reader ~20% faster and slightly smaller, so it is now enabled by default via `ZXING_WASM_LTO`)
 
