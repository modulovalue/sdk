// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Rust reference benchmark for BitArray cardinality, mirroring the Dart
// version in ../dart/BitArray.dart and the C version in
// ../c/bitarray_bench.c. Uses u32::count_ones as the "intrinsic" path
// and a hand-written SWAR Hamming weight as the software path, with
// both un-unrolled and 8-way unrolled variants.
//
// Build: rustc -C opt-level=3 bitarray_bench.rs -o bitarray_bench_rs
// Run:   ./bitarray_bench_rs

use std::hint::black_box;
use std::time::Instant;

const BENCH_BITS: usize = 1 << 20;
const WORD_BITS: usize = 32;
const N_WORDS: usize = (BENCH_BITS + WORD_BITS - 1) / WORD_BITS;

fn fill_quarter_density(w: &mut [u32]) {
    // Match C's xorshift32 + AND-of-two so the bit pattern is identical.
    let mut s: u32 = 0xBEEF;
    for slot in w.iter_mut() {
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        let r1 = s;
        s ^= s << 13;
        s ^= s >> 17;
        s ^= s << 5;
        let r2 = s;
        *slot = r1 & r2;
    }
}

// ----- cardinality kernels --------------------------------------------------

#[inline(never)]
fn cardinality_intrinsic(w: &[u32]) -> u32 {
    let mut total = 0u32;
    for &v in w {
        total += v.count_ones();
    }
    total
}

#[inline(never)]
fn cardinality_intrinsic_unrolled(w: &[u32]) -> u32 {
    let n = w.len();
    let limit = n - (n & 7);
    let mut total = 0u32;
    let mut i = 0;
    while i < limit {
        total += w[i].count_ones()
            + w[i + 1].count_ones()
            + w[i + 2].count_ones()
            + w[i + 3].count_ones()
            + w[i + 4].count_ones()
            + w[i + 5].count_ones()
            + w[i + 6].count_ones()
            + w[i + 7].count_ones();
        i += 8;
    }
    while i < n {
        total += w[i].count_ones();
        i += 1;
    }
    total
}

#[inline(never)]
fn cardinality_swar(w: &[u32]) -> u32 {
    let mut total = 0u32;
    for &word in w {
        let mut v = word;
        v = v.wrapping_sub((v >> 1) & 0x55555555);
        v = (v & 0x33333333).wrapping_add((v >> 2) & 0x33333333);
        v = v.wrapping_add(v >> 4) & 0x0F0F0F0F;
        total += v.wrapping_mul(0x01010101) >> 24;
    }
    total
}

#[inline(never)]
fn cardinality_swar_unrolled(w: &[u32]) -> u32 {
    let n = w.len();
    let limit = n - (n & 7);
    let mut total = 0u32;
    let mut i = 0;
    while i < limit {
        let mut a = w[i];
        let mut b = w[i + 1];
        let mut c = w[i + 2];
        let mut d = w[i + 3];
        let mut e = w[i + 4];
        let mut f = w[i + 5];
        let mut g = w[i + 6];
        let mut h = w[i + 7];
        a = a.wrapping_sub((a >> 1) & 0x55555555);
        b = b.wrapping_sub((b >> 1) & 0x55555555);
        c = c.wrapping_sub((c >> 1) & 0x55555555);
        d = d.wrapping_sub((d >> 1) & 0x55555555);
        e = e.wrapping_sub((e >> 1) & 0x55555555);
        f = f.wrapping_sub((f >> 1) & 0x55555555);
        g = g.wrapping_sub((g >> 1) & 0x55555555);
        h = h.wrapping_sub((h >> 1) & 0x55555555);
        a = (a & 0x33333333).wrapping_add((a >> 2) & 0x33333333);
        b = (b & 0x33333333).wrapping_add((b >> 2) & 0x33333333);
        c = (c & 0x33333333).wrapping_add((c >> 2) & 0x33333333);
        d = (d & 0x33333333).wrapping_add((d >> 2) & 0x33333333);
        e = (e & 0x33333333).wrapping_add((e >> 2) & 0x33333333);
        f = (f & 0x33333333).wrapping_add((f >> 2) & 0x33333333);
        g = (g & 0x33333333).wrapping_add((g >> 2) & 0x33333333);
        h = (h & 0x33333333).wrapping_add((h >> 2) & 0x33333333);
        a = a.wrapping_add(a >> 4) & 0x0F0F0F0F;
        b = b.wrapping_add(b >> 4) & 0x0F0F0F0F;
        c = c.wrapping_add(c >> 4) & 0x0F0F0F0F;
        d = d.wrapping_add(d >> 4) & 0x0F0F0F0F;
        e = e.wrapping_add(e >> 4) & 0x0F0F0F0F;
        f = f.wrapping_add(f >> 4) & 0x0F0F0F0F;
        g = g.wrapping_add(g >> 4) & 0x0F0F0F0F;
        h = h.wrapping_add(h >> 4) & 0x0F0F0F0F;
        total += a.wrapping_mul(0x01010101) >> 24;
        total += b.wrapping_mul(0x01010101) >> 24;
        total += c.wrapping_mul(0x01010101) >> 24;
        total += d.wrapping_mul(0x01010101) >> 24;
        total += e.wrapping_mul(0x01010101) >> 24;
        total += f.wrapping_mul(0x01010101) >> 24;
        total += g.wrapping_mul(0x01010101) >> 24;
        total += h.wrapping_mul(0x01010101) >> 24;
        i += 8;
    }
    while i < n {
        let mut v = w[i];
        v = v.wrapping_sub((v >> 1) & 0x55555555);
        v = (v & 0x33333333).wrapping_add((v >> 2) & 0x33333333);
        v = v.wrapping_add(v >> 4) & 0x0F0F0F0F;
        total += v.wrapping_mul(0x01010101) >> 24;
        i += 1;
    }
    total
}

// ----- harness --------------------------------------------------------------

fn bench(name: &str, fn_: impl Fn(&[u32]) -> u32, w: &[u32]) {
    // Warmup.
    for _ in 0..16 {
        black_box(fn_(black_box(w)));
    }
    // Calibrate to roughly 100 ms wall.
    let target_us = 100_000u128;
    let t0 = Instant::now();
    let mut iters = 0u32;
    while (t0.elapsed().as_micros()) < target_us {
        black_box(fn_(black_box(w)));
        iters += 1;
    }
    let elapsed_us = t0.elapsed().as_micros() as f64;
    let us_per_iter = elapsed_us / (iters as f64);
    println!("BitArray.{}(RunTime): {:.4} us.", name, us_per_iter);
}

fn main() {
    let mut bits = vec![0u32; N_WORDS];
    fill_quarter_density(&mut bits);

    // Sanity: all four kernels must agree.
    let c1 = cardinality_intrinsic(&bits);
    let c2 = cardinality_intrinsic_unrolled(&bits);
    let c3 = cardinality_swar(&bits);
    let c4 = cardinality_swar_unrolled(&bits);
    assert_eq!(c1, c2);
    assert_eq!(c1, c3);
    assert_eq!(c1, c4);
    eprintln!("cardinality (sanity check) = {} / {}", c1, BENCH_BITS);

    bench("cardinality.swar", cardinality_swar, &bits);
    bench("cardinality.swar.unrolled", cardinality_swar_unrolled, &bits);
    bench("cardinality.intrinsic", cardinality_intrinsic, &bits);
    bench("cardinality.intrinsic.unrolled", cardinality_intrinsic_unrolled, &bits);
}
