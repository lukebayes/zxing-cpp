/*
* Copyright 2016 Nu-book Inc.
* Copyright 2016 ZXing authors
*/
// SPDX-License-Identifier: Apache-2.0

#include "HybridBinarizer.h"

#include "BitMatrix.h"
#include "Matrix.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <memory>
#include <vector>

#define USE_NEW_ALGORITHM

namespace ZXing {

// This class uses 5x5 blocks to compute local luminance, where each block is 8x8 pixels.
// So this is the smallest dimension in each axis we can accept.
static constexpr int BLOCK_SIZE = 8;
static constexpr int WINDOW_SIZE = BLOCK_SIZE * (1 + 2 * 2);
static constexpr int MIN_DYNAMIC_RANGE = 24;
static constexpr int MAX_DYNAMIC_RANGE_THRESHOLD = 96;

HybridBinarizer::HybridBinarizer(const ImageView& iv) : GlobalHistogramBinarizer(iv) {}

HybridBinarizer::~HybridBinarizer() = default;

bool HybridBinarizer::getPatternRow(int row, int rotation, PatternRow& res) const
{
#if 1
	// This is the original "hybrid" behavior: use GlobalHistogram for the 1D case
	return GlobalHistogramBinarizer::getPatternRow(row, rotation, res);
#else
	// This is an alternative that can be faster in general and perform better in unevenly lit situations like
	// https://github.com/zxing-cpp/zxing-cpp/blob/master/test/samples/ean13-2/21.png. That said, it fairs
	// worse in borderline low resolution situations. With the current black box sample set we'd loose 94
	// test cases while gaining 53 others.
	auto bits = getBitMatrix();
	if (bits)
		GetPatternRow(*bits, row, res, rotation % 180 != 0);
	return bits != nullptr;
#endif
}

using T_t = uint8_t;

/**
* Applies a single threshold to a block of pixels.
*/
static void ThresholdBlock(const uint8_t* __restrict luminances, int xoffset, int yoffset, T_t threshold, int rowStride,
						   BitMatrix& matrix)
{
	for (int y = yoffset; y < yoffset + BLOCK_SIZE; ++y) {
		auto* src = luminances + y * rowStride + xoffset;
		auto* const dstBegin = matrix.row(y).begin() + xoffset;
		// TODO: fix pixelStride > 1 case
		for (auto* dst = dstBegin; dst < dstBegin + BLOCK_SIZE; ++dst, ++src)
			*dst = (*src <= threshold) * BitMatrix::SET_V;
	}
}

#ifndef USE_NEW_ALGORITHM

/**
* Calculates a single black point for each block of pixels and saves it away.
* See the following thread for a discussion of this algorithm:
*  http://groups.google.com/group/zxing/browse_thread/thread/d06efa2c35a7ddc0
*/
static Matrix<T_t> CalculateBlackPoints(const uint8_t* __restrict luminances, int subWidth, int subHeight, int width, int height,
										int rowStride)
{
	Matrix<T_t> blackPoints(subWidth, subHeight);

	for (int y = 0; y < subHeight; y++) {
		int yoffset = std::min(y * BLOCK_SIZE, height - BLOCK_SIZE);
		for (int x = 0; x < subWidth; x++) {
			int xoffset = std::min(x * BLOCK_SIZE, width - BLOCK_SIZE);
			int sum = 0;
			uint8_t min = luminances[yoffset * rowStride + xoffset];
			uint8_t max = min;
			for (int yy = 0, offset = yoffset * rowStride + xoffset; yy < BLOCK_SIZE; yy++, offset += rowStride) {
				for (int xx = 0; xx < BLOCK_SIZE; xx++) {
					auto pixel = luminances[offset + xx];
					sum += pixel;
					if (pixel < min)
						min = pixel;
					if (pixel > max)
						max = pixel;
				}
				// short-circuit min/max tests once dynamic range is met
				if (max - min > MIN_DYNAMIC_RANGE) {
					// finish the rest of the rows quickly
					for (yy++, offset += rowStride; yy < BLOCK_SIZE; yy++, offset += rowStride) {
						for (int xx = 0; xx < BLOCK_SIZE; xx++) {
							sum += luminances[offset + xx];
						}
					}
				}
			}

			// The default estimate is the average of the values in the block.
			int average = sum / (BLOCK_SIZE * BLOCK_SIZE);
			if (max - min <= MIN_DYNAMIC_RANGE) {
				// If variation within the block is low, assume this is a block with only light or only
				// dark pixels. In that case we do not want to use the average, as it would divide this
				// low contrast area into black and white pixels, essentially creating data out of noise.
				//
				// The default assumption is that the block is light/background. Since no estimate for
				// the level of dark pixels exists locally, use half the min for the block.
				average = min / 2;

				if (y > 0 && x > 0) {
					// Correct the "white background" assumption for blocks that have neighbors by comparing
					// the pixels in this block to the previously calculated black points. This is based on
					// the fact that dark barcode symbology is always surrounded by some amount of light
					// background for which reasonable black point estimates were made. The bp estimated at
					// the boundaries is used for the interior.

					// The (min < bp) is arbitrary but works better than other heuristics that were tried.
					int averageNeighborBlackPoint =
						(blackPoints(x, y - 1) + (2 * blackPoints(x - 1, y)) + blackPoints(x - 1, y - 1)) / 4;
					if (min < averageNeighborBlackPoint) {
						average = averageNeighborBlackPoint;
					}
				}
			}
			blackPoints(x, y) = average;
		}
	}
	return blackPoints;
}

/**
* For each block in the image, calculate the average black point using a 5x5 grid
* of the blocks around it. Also handles the corner cases (fractional blocks are computed based
* on the last pixels in the row/column which are also used in the previous block).
*/
static std::shared_ptr<BitMatrix> CalculateMatrix(const uint8_t* __restrict luminances, int subWidth, int subHeight, int width,
												  int height, int rowStride, const Matrix<T_t>& blackPoints)
{
	auto matrix = std::make_shared<BitMatrix>(width, height);

#ifdef PRINT_DEBUG
	Matrix<uint8_t> out(width, height);
	Matrix<uint8_t> out2(width, height);
#endif

	for (int y = 0; y < subHeight; y++) {
		int yoffset = std::min(y * BLOCK_SIZE, height - BLOCK_SIZE);
		for (int x = 0; x < subWidth; x++) {
			int xoffset = std::min(x * BLOCK_SIZE, width - BLOCK_SIZE);
			int left = std::clamp(x, 2, subWidth - 3);
			int top = std::clamp(y, 2, subHeight - 3);
			int sum = 0;
			for (int dy = -2; dy <= 2; ++dy) {
				for (int dx = -2; dx <= 2; ++dx) {
					sum += blackPoints(left + dx, top + dy);
				}
			}
			int average = sum / 25;
			ThresholdBlock(luminances, xoffset, yoffset, average, rowStride, *matrix);

#ifdef PRINT_DEBUG
			for (int yy = 0; yy < 8; ++yy)
				for (int xx = 0; xx < 8; ++xx) {
					out.set(xoffset + xx, yoffset + yy, blackPoints(x, y));
					out2.set(xoffset + xx, yoffset + yy, average);
				}
#endif
		}
	}

#ifdef PRINT_DEBUG
	std::ofstream file("thresholds.pnm");
	file << "P5\n" << out.width() << ' ' << out.height() << "\n255\n";
	file.write(reinterpret_cast<const char*>(out.data()), out.size());
	std::ofstream file2("thresholds_avg.pnm");
	file2 << "P5\n" << out.width() << ' ' << out.height() << "\n255\n";
	file2.write(reinterpret_cast<const char*>(out2.data()), out2.size());
#endif

	return matrix;
}

#else

// Subdivide the image in blocks of BLOCK_SIZE and calculate one threshold value per block as
// (max - min > minRange) ? (max + min) / 2 : 0, where minRange is at least MIN_DYNAMIC_RANGE but grows with
// the noise level of the image
static Matrix<T_t> BlockThresholds(const ImageView iv)
{
	int subWidth = (iv.width() + BLOCK_SIZE - 1) / BLOCK_SIZE; // ceil(width/BS)
	int subHeight = (iv.height() + BLOCK_SIZE - 1) / BLOCK_SIZE; // ceil(height/BS)

	Matrix<T_t> thresholds(subWidth, subHeight);
	Matrix<uint8_t> ranges(subWidth, subHeight);
	std::array<int, 256> hist = {};

	// First reduce the BLOCK_SIZE rows of a block row to per-column min/max values, then reduce those per block.
	// Processing whole rows instead of 8x8 blocks lets the compiler vectorize the inner loops.
	std::vector<uint8_t> colMin(iv.width()), colMax(iv.width());
	for (int y = 0; y < subHeight; y++) {
		int y0 = std::min(y * BLOCK_SIZE, iv.height() - BLOCK_SIZE);
		std::copy_n(iv.data(0, y0), iv.width(), colMin.data());
		std::copy_n(iv.data(0, y0), iv.width(), colMax.data());
		for (int yy = 1; yy < BLOCK_SIZE; yy++) {
			const uint8_t* __restrict line = iv.data(0, y0 + yy);
			uint8_t* __restrict mins = colMin.data();
			uint8_t* __restrict maxs = colMax.data();
			for (int x = 0; x < iv.width(); x++) {
				mins[x] = std::min(mins[x], line[x]);
				maxs[x] = std::max(maxs[x], line[x]);
			}
		}

		for (int x = 0; x < subWidth; x++) {
			int x0 = std::min(x * BLOCK_SIZE, iv.width() - BLOCK_SIZE);
			uint8_t min = colMin[x0];
			uint8_t max = colMax[x0];
			for (int xx = 1; xx < BLOCK_SIZE; ++xx) {
				min = std::min(min, colMin[x0 + xx]);
				max = std::max(max, colMax[x0 + xx]);
			}

			thresholds(x, y) = (int(max) + min) / 2;
			ranges(x, y) = max - min;
			++hist[max - min];
		}
	}

	// Sensor noise (e.g. from a camera in low light) inflates the range of otherwise flat blocks. Thresholding those
	// at their midpoint turns flat background into salt-and-pepper noise, which hurts detection and wastes time in
	// the detectors. Estimate the noise floor as the 25th percentile of all block ranges (most of a typical frame is
	// background) and require a block to exceed it by a factor of 2 before trusting its threshold.
	int target = thresholds.size() / 4, noiseRange = 0;
	for (int acc = hist[0]; acc < target && noiseRange < 255; acc += hist[++noiseRange])
		;
	int minRange = std::clamp(2 * noiseRange, MIN_DYNAMIC_RANGE, MAX_DYNAMIC_RANGE_THRESHOLD);

	for (auto t = thresholds.begin(), r = ranges.begin(); t != thresholds.end(); ++t, ++r)
		if (*r <= minRange)
			*t = 0;

	return thresholds;
}

// Apply gaussian-like smoothing filter over all non-zero thresholds and fill any remaining gaps with nearest neighbor
static Matrix<T_t> SmoothThresholds(Matrix<T_t>&& in)
{
	Matrix<T_t> out(in.width(), in.height());

	constexpr int R = WINDOW_SIZE / BLOCK_SIZE / 2;
	// Summed-area tables of the thresholds and of the number of non-zero thresholds let us compute the sum over each
	// (2R+1)x(2R+1) window in constant time.
	const int w = in.width(), h = in.height(), sw = w + 1;
	std::vector<int> sums(sw * (h + 1)), counts(sw * (h + 1));
	for (int y = 0; y < h; y++) {
		const T_t* row = in.data() + y * w;
		int rowSum = 0, rowCount = 0;
		for (int x = 0; x < w; x++) {
			rowSum += row[x];
			rowCount += row[x] > 0;
			sums[(y + 1) * sw + x + 1] = sums[y * sw + x + 1] + rowSum;
			counts[(y + 1) * sw + x + 1] = counts[y * sw + x + 1] + rowCount;
		}
	}
	auto window = [sw](const std::vector<int>& table, int left, int top) {
		int x0 = left - R, x1 = left + R + 1, y0 = top - R, y1 = top + R + 1;
		return table[y1 * sw + x1] - table[y0 * sw + x1] - table[y1 * sw + x0] + table[y0 * sw + x0];
	};

	T_t* dst = out.begin();
	for (int y = 0; y < h; y++) {
		int top = std::clamp(y, R, h - R - 1);
		for (int x = 0; x < w; x++) {
			int left = std::clamp(x, R, w - R - 1);
			int t = in.data()[y * w + x];
			int sum = t * 2 + window(sums, left, top);
			int n = (t > 0) * 2 + window(counts, left, top);
			*dst++ = n > 0 ? sum / n : 0;
		}
	}

	// flood fill any remaining gaps of (very large) no-contrast regions
	auto last = out.begin() - 1;
	for (auto* i = out.begin(); i != out.end(); ++i) {
		if (*i) {
			if (last != i - 1)
				std::fill(last + 1, i, *i);
			last = i;
		}
	}
	std::fill(last + 1, out.end(), *(std::max(last, out.begin())));

	return out;
}

static std::shared_ptr<BitMatrix> ThresholdImage(const ImageView iv, const Matrix<T_t>& thresholds)
{
	auto matrix = std::make_shared<BitMatrix>(iv.width(), iv.height());

#ifdef PRINT_DEBUG
	Matrix<uint8_t> out(iv.width(), iv.height());
#endif

	// Expand the block thresholds of a block row into one threshold per pixel column, then threshold whole rows,
	// which the compiler can vectorize. Overlapping last blocks are handled like in ThresholdBlock: later ones win.
	std::vector<T_t> rowThresholds(iv.width());
	for (int y = 0; y < thresholds.height(); y++) {
		int y0 = std::min(y * BLOCK_SIZE, iv.height() - BLOCK_SIZE);
		for (int x = 0; x < thresholds.width(); x++)
			std::fill_n(rowThresholds.data() + std::min(x * BLOCK_SIZE, iv.width() - BLOCK_SIZE), BLOCK_SIZE, thresholds(x, y));

		for (int yy = y0; yy < y0 + BLOCK_SIZE; ++yy) {
			const uint8_t* __restrict src = iv.data(0, yy);
			const T_t* __restrict thr = rowThresholds.data();
			auto* __restrict dst = matrix->row(yy).begin();
			for (int x = 0; x < iv.width(); ++x)
				dst[x] = src[x] <= thr[x] ? BitMatrix::SET_V : BitMatrix::UNSET_V;
		}
	}

#ifdef PRINT_DEBUG
	for (int y = 0; y < thresholds.height(); y++)
		for (int x = 0; x < thresholds.width(); x++)
			for (int yy = 0; yy < BLOCK_SIZE; ++yy)
				for (int xx = 0; xx < BLOCK_SIZE; ++xx)
					out.set(std::min(x * BLOCK_SIZE, iv.width() - BLOCK_SIZE) + xx, std::min(y * BLOCK_SIZE, iv.height() - BLOCK_SIZE) + yy,
							thresholds(x, y));

	std::ofstream file("thresholds_new.pnm");
	file << "P5\n" << out.width() << ' ' << out.height() << "\n255\n";
	file.write(reinterpret_cast<const char*>(out.data()), out.size());
#endif

	return matrix;
}

#endif

std::shared_ptr<const BitMatrix> HybridBinarizer::getBlackMatrix() const
{
	if (width() >= WINDOW_SIZE && height() >= WINDOW_SIZE) {
#ifdef USE_NEW_ALGORITHM
		auto thrs = SmoothThresholds(BlockThresholds(_buffer));
		if (std::ranges::max(thrs) == 0)
			return GlobalHistogramBinarizer::getBlackMatrix();
		return ThresholdImage(_buffer, thrs);
#else
		const uint8_t* luminances = _buffer.data();
		int subWidth = (width() + BLOCK_SIZE - 1) / BLOCK_SIZE; // ceil(width/BS)
		int subHeight = (height() + BLOCK_SIZE - 1) / BLOCK_SIZE; // ceil(height/BS)
		auto blackPoints =
			CalculateBlackPoints(luminances, subWidth, subHeight, width(), height(), _buffer.rowStride());

		return CalculateMatrix(luminances, subWidth, subHeight, width(), height(), _buffer.rowStride(), blackPoints);
#endif
	} else {
		// If the image is too small, fall back to the global histogram approach.
		return GlobalHistogramBinarizer::getBlackMatrix();
	}
}

} // ZXing
