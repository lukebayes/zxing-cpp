# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ZXing-C++ is a multi-format barcode image processing library implemented in C++20/C++17. It can both read and write barcodes in numerous formats including QR Code, DataMatrix, Aztec, PDF417, and various 1D formats (UPC, EAN, Code 128, etc.).

## Build System

The project uses CMake with a modular architecture. The main library is in `core/`, with language-specific wrappers in `wrappers/`.

### Common Build Commands

**Basic build:**
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8 --config Release
```

**Development build with all features:**
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DZXING_READERS=ON \
  -DZXING_WRITERS=ON \
  -DZXING_EXAMPLES=ON \
  -DZXING_UNIT_TESTS=ON \
  -DZXING_BLACKBOX_TESTS=ON \
  -DZXING_C_API=ON
cmake --build build -j8 --config Release
```

**Build with experimental API (new writer backend):**
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DZXING_WRITERS=NEW \
  -DZXING_EXPERIMENTAL_API=ON
cmake --build build -j8
```

### Running Tests

**Run all tests:**
```bash
ctest --test-dir build -V -C Release
```

**Run unit tests only:**
```bash
./build/test/unit/UnitTest
```

**Run blackbox tests (reader/writer validation):**
```bash
./build/test/blackbox/ReaderTest test/samples
./build/test/blackbox/WriterTest
```

**Run a single test with GTest filter:**
```bash
./build/test/unit/UnitTest --gtest_filter="BarcodeFormatTest.*"
```

### CMake Configuration Options

- `ZXING_READERS` (ON/OFF) - Enable barcode reading/decoding
- `ZXING_WRITERS` (OFF/ON/OLD/NEW/BOTH) - Enable barcode writing/encoding
  - `OLD` = legacy writer backend
  - `NEW` = new libzint-based backend (requires `ZXING_EXPERIMENTAL_API=ON`)
  - `BOTH` = include both backends
- `ZXING_EXPERIMENTAL_API` (ON/OFF) - Enable experimental API features
- `ZXING_C_API` (ON/OFF) - Build C API wrapper
- `ZXING_EXAMPLES` (ON/OFF) - Build example applications
- `ZXING_UNIT_TESTS` (ON/OFF) - Build unit tests
- `ZXING_BLACKBOX_TESTS` (ON/OFF) - Build blackbox tests
- `ZXING_PYTHON_MODULE` (ON/OFF) - Build Python bindings
- `BUILD_SHARED_LIBS` (ON/OFF) - Build as shared library vs static
- `ZXING_ENABLE_<FORMAT>` (ON/OFF) - Enable specific formats (1D, AZTEC, DATAMATRIX, MAXICODE, PDF417, QRCODE)

## Architecture

### Core Library Structure

**`core/src/`** - Main library source
- Top-level files: Common infrastructure (Barcode, BarcodeFormat, BitMatrix, ImageView, ReadBarcode, WriteBarcode, etc.)
- `aztec/` - Aztec barcode reader/writer
- `datamatrix/` - DataMatrix barcode reader/writer
- `maxicode/` - MaxiCode barcode reader
- `oned/` - 1D barcode readers/writers (UPC, EAN, Code39, Code93, Code128, Codabar, ITF, DataBar, etc.)
- `pdf417/` - PDF417 barcode reader/writer
- `qrcode/` - QR Code, Micro QR, rMQR reader/writer
- `libzint/` - Bundled libzint for new writer backend
- `libzueci/` - Bundled libzueci for character encoding

### Key API Entry Points

**Reading barcodes:**
- `core/src/ReadBarcode.h` - Main API: `ReadBarcode()` and `ReadBarcodes()`
- `core/src/ReaderOptions.h` - Configuration for detection/decoding
- `core/src/Barcode.h` - Result structure with format, text, position, etc.
- `core/src/ImageView.h` - Image data wrapper (supports various formats)

**Writing barcodes (OLD API):**
- `core/src/MultiFormatWriter.h` - Legacy writer API
- `core/src/BitMatrix.h` - Binary barcode image representation

**Writing barcodes (NEW API, requires ZXING_EXPERIMENTAL_API):**
- `core/src/WriteBarcode.h` - New experimental writer API

**Example code:**
- `example/ZXingReader.cpp` - Full-featured command-line reader
- `example/ZXingWriter.cpp` - Command-line writer with examples of both old and new APIs

### Format-Specific Implementation Pattern

Each barcode format follows a consistent pattern:
- **Reader**: `<Format>Reader` class (e.g., `QRReader`, `AZReader`, `ODCode128Reader`)
- **Decoder**: `<Format>Decoder` class - decodes from bit matrix to data
- **Detector**: `<Format>Detector` class - finds barcode position in image
- **Writer** (OLD): `<Format>Writer` class - encodes data to bit matrix
- **Encoder** (OLD): `<Format>Encoder` class - high-level encoding logic

### Binarization Pipeline

Images are converted to binary using one of three binarizers (selected via `ReaderOptions`):
- `GlobalHistogramBinarizer` - Global threshold based on histogram
- `HybridBinarizer` - Adaptive local thresholding (default, best for most cases)
- `FixedThreshold` - Simple 50% threshold (for "pure" barcodes only)

The `BinaryBitmap` class wraps the binarizer and provides access to binary image data for detection/decoding.

### Wrappers

Language bindings are in `wrappers/`:
- `android/` - Android JNI wrapper
- `c/` - C API wrapper (`ZXingC.h`)
- `dotnet/` - .NET wrapper
- `ios/` - iOS wrapper
- `kn/` - Kotlin/Native wrapper
- `python/` - Python bindings (pybind11)
- `rust/` - Rust bindings
- `wasm/` - WebAssembly build
- `winrt/` - WinRT wrapper

Each wrapper has its own README with build instructions.

## Code Standards

- **C++ Standard**: C++20 preferred, C++17 minimum (some features require C++20)
- **No third-party dependencies** for core library (tests/examples use stb_image, Google Test, fmt)
- **Thread-safe** library design
- **clang-format** configuration provided in `.clang-format`

## Testing Strategy

- **Unit tests** (`test/unit/`) - Test individual components using Google Test
- **Blackbox tests** (`test/blackbox/`) - Validate reader/writer against real barcode images in `test/samples/`
- **CI** runs tests on Windows, Linux, macOS (see `.github/workflows/ci.yml`)

## Development Notes

- When building C++17 only (vs C++20), the library lacks support for:
  - DataBarLimited format
  - Multi-symbol detection for DataMatrix
  - Position-independent detection for DataMatrix

- The experimental API and new writer backend (libzint) are under active development. For production use, prefer the stable OLD writer backend unless specifically needing new format support.

- Format detection performance can be optimized via `ReaderOptions`:
  - Specify exact formats with `setFormats()`
  - Disable unnecessary detection passes: `setTryRotate(false)`, `setTryInvert(false)`, `setTryDownscale(false)`
  - Use `setIsPure(true)` for perfect/isolated barcodes

- The library supports structured append (reading multiple barcodes that form one message) for QR Code, DataMatrix, Aztec, and PDF417.
