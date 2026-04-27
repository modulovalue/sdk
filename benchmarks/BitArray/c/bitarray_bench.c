// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// C reference benchmark for BitArray cardinality, mirroring the Dart
// version in ../dart/BitArray.dart. Uses __builtin_popcount as the
// "intrinsic" path and a hand-written SWAR Hamming weight as the
// software path, with both un-unrolled and 8-way unrolled variants.
//
// Compile: cc -O3 -std=c11 bitarray_bench.c -o bitarray_bench
// Run:     ./bitarray_bench

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define BENCH_BITS (1u << 20)
#define WORD_BITS  32
#define WORD_SHIFT 5
#define WORD_MASK  (WORD_BITS - 1)
#define N_WORDS    ((BENCH_BITS + WORD_BITS - 1) >> WORD_SHIFT)

// Match BenchmarkBase's reporting unit: microseconds per single run() call.
// To pick an iteration count, we measure once at ~50 ms and scale.

static uint32_t bits[N_WORDS];

static void fill_quarter_density(uint32_t* w, size_t n) {
  // Deterministic xorshift32 with a fixed seed, then keep only ~25% of bits.
  uint32_t s = 0xBEEFu;
  for (size_t i = 0; i < n; i++) {
    // 4 random uint32s combined: AND any 2 of 4 -> ~25% bit density.
    uint32_t r1, r2;
    s ^= s << 13; s ^= s >> 17; s ^= s << 5; r1 = s;
    s ^= s << 13; s ^= s >> 17; s ^= s << 5; r2 = s;
    w[i] = r1 & r2;
  }
}

// ----- cardinality kernels --------------------------------------------------

static int cardinality_intrinsic(const uint32_t* w, size_t n) {
  int total = 0;
  for (size_t i = 0; i < n; i++) {
    total += __builtin_popcount(w[i]);
  }
  return total;
}

static int cardinality_intrinsic_unrolled(const uint32_t* w, size_t n) {
  size_t limit = n - (n & 7);
  int total = 0;
  for (size_t i = 0; i < limit; i += 8) {
    total +=
        __builtin_popcount(w[i]) +
        __builtin_popcount(w[i + 1]) +
        __builtin_popcount(w[i + 2]) +
        __builtin_popcount(w[i + 3]) +
        __builtin_popcount(w[i + 4]) +
        __builtin_popcount(w[i + 5]) +
        __builtin_popcount(w[i + 6]) +
        __builtin_popcount(w[i + 7]);
  }
  for (size_t i = limit; i < n; i++) {
    total += __builtin_popcount(w[i]);
  }
  return total;
}

static int cardinality_swar(const uint32_t* w, size_t n) {
  int total = 0;
  for (size_t i = 0; i < n; i++) {
    uint32_t v = w[i];
    v = v - ((v >> 1) & 0x55555555u);
    v = (v & 0x33333333u) + ((v >> 2) & 0x33333333u);
    v = (v + (v >> 4)) & 0x0F0F0F0Fu;
    total += (int)((v * 0x01010101u) >> 24);
  }
  return total;
}

static int cardinality_swar_unrolled(const uint32_t* w, size_t n) {
  size_t limit = n - (n & 7);
  int total = 0;
  for (size_t i = 0; i < limit; i += 8) {
    uint32_t a = w[i], b = w[i + 1], c = w[i + 2], d = w[i + 3];
    uint32_t e = w[i + 4], f = w[i + 5], g = w[i + 6], h = w[i + 7];
    a = a - ((a >> 1) & 0x55555555u);
    b = b - ((b >> 1) & 0x55555555u);
    c = c - ((c >> 1) & 0x55555555u);
    d = d - ((d >> 1) & 0x55555555u);
    e = e - ((e >> 1) & 0x55555555u);
    f = f - ((f >> 1) & 0x55555555u);
    g = g - ((g >> 1) & 0x55555555u);
    h = h - ((h >> 1) & 0x55555555u);
    a = (a & 0x33333333u) + ((a >> 2) & 0x33333333u);
    b = (b & 0x33333333u) + ((b >> 2) & 0x33333333u);
    c = (c & 0x33333333u) + ((c >> 2) & 0x33333333u);
    d = (d & 0x33333333u) + ((d >> 2) & 0x33333333u);
    e = (e & 0x33333333u) + ((e >> 2) & 0x33333333u);
    f = (f & 0x33333333u) + ((f >> 2) & 0x33333333u);
    g = (g & 0x33333333u) + ((g >> 2) & 0x33333333u);
    h = (h & 0x33333333u) + ((h >> 2) & 0x33333333u);
    a = (a + (a >> 4)) & 0x0F0F0F0Fu;
    b = (b + (b >> 4)) & 0x0F0F0F0Fu;
    c = (c + (c >> 4)) & 0x0F0F0F0Fu;
    d = (d + (d >> 4)) & 0x0F0F0F0Fu;
    e = (e + (e >> 4)) & 0x0F0F0F0Fu;
    f = (f + (f >> 4)) & 0x0F0F0F0Fu;
    g = (g + (g >> 4)) & 0x0F0F0F0Fu;
    h = (h + (h >> 4)) & 0x0F0F0F0Fu;
    total +=
        (int)((a * 0x01010101u) >> 24) +
        (int)((b * 0x01010101u) >> 24) +
        (int)((c * 0x01010101u) >> 24) +
        (int)((d * 0x01010101u) >> 24) +
        (int)((e * 0x01010101u) >> 24) +
        (int)((f * 0x01010101u) >> 24) +
        (int)((g * 0x01010101u) >> 24) +
        (int)((h * 0x01010101u) >> 24);
  }
  for (size_t i = limit; i < n; i++) {
    uint32_t v = w[i];
    v = v - ((v >> 1) & 0x55555555u);
    v = (v & 0x33333333u) + ((v >> 2) & 0x33333333u);
    v = (v + (v >> 4)) & 0x0F0F0F0Fu;
    total += (int)((v * 0x01010101u) >> 24);
  }
  return total;
}

// ----- harness --------------------------------------------------------------

static double now_us(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static volatile int sink;

static void bench(const char* name, int (*fn)(const uint32_t*, size_t)) {
  // Warmup.
  for (int i = 0; i < 16; i++) sink ^= fn(bits, N_WORDS);

  // Calibrate iteration count to roughly 100 ms.
  double t0 = now_us();
  int iters = 0;
  int target_us = 100000;
  while (now_us() - t0 < target_us) {
    sink ^= fn(bits, N_WORDS);
    iters++;
  }
  double elapsed = now_us() - t0;
  double us_per_iter = elapsed / iters;
  printf("BitArray.%s(RunTime): %.4f us.\n", name, us_per_iter);
}

int main(void) {
  fill_quarter_density(bits, N_WORDS);

  // Sanity: all four kernels must agree.
  int c1 = cardinality_intrinsic(bits, N_WORDS);
  int c2 = cardinality_intrinsic_unrolled(bits, N_WORDS);
  int c3 = cardinality_swar(bits, N_WORDS);
  int c4 = cardinality_swar_unrolled(bits, N_WORDS);
  if (c1 != c2 || c1 != c3 || c1 != c4) {
    fprintf(stderr, "FAIL: %d %d %d %d\n", c1, c2, c3, c4);
    return 1;
  }
  fprintf(stderr, "cardinality (sanity check) = %d / %u\n", c1, BENCH_BITS);

  bench("cardinality.swar", cardinality_swar);
  bench("cardinality.swar.unrolled", cardinality_swar_unrolled);
  bench("cardinality.intrinsic", cardinality_intrinsic);
  bench("cardinality.intrinsic.unrolled", cardinality_intrinsic_unrolled);

  return 0;
}
