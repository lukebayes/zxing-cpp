// Smoke test for the wasm wrapper: encode barcodes with generateBarcode and decode them again.
// Requires a build configured with -DZXING_EMSCRIPTEN_ENVIRONMENT=node.
// Usage: node test_roundtrip.js <path to zxing.js>

const path = require("path");
const ZXing = require(path.resolve(process.argv[2] || "zxing.js"));

const cases = [
	["QRCode", "Hello WASM"],
	["DataMatrix", "zxing-cpp"],
	["Aztec", "AZTEC123"],
	["PDF417", "pdf417 text"],
	["Code128", "CODE128-42"],
	["EAN-13", "9780201379624"],
];

ZXing().then(zxing => {
	let failures = 0;
	for (const [format, text] of cases) {
		const written = zxing.generateBarcode(text, format, "UTF8", 10, 200, 200, -1);
		if (written.error) {
			console.log("FAIL", format, "write error:", written.error);
			failures++;
			written.delete();
			continue;
		}
		const png = written.image;
		const buffer = zxing._malloc(png.length);
		zxing.HEAPU8.set(png, buffer);
		const results = zxing.readBarcodesFromImage(buffer, png.length, true, format, 1);
		zxing._free(buffer);
		written.delete();

		const result = results.size() ? results.get(0) : { text: "", format: "", error: "no barcode found" };
		const ok = result.text === text;
		if (!ok)
			failures++;
		console.log(ok ? "OK  " : "FAIL", format.padEnd(10), JSON.stringify(result.text), result.error);
	}
	process.exit(failures ? 1 : 0);
});
