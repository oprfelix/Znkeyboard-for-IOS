#!/usr/bin/env python3
"""Builds pinyin_char_trigram.bin, the letter model for typing pinyin, from Android's dict.tsv.

Same file as en_char_trigram.bin: P(c | a, b) over {boundary, a..z}, one byte per trigram holding
-16 log2 P. Words are weighted by frequency, and because a composition runs words together, each
word's end is followed by the starts of all words. English letters read pinyin badly: after q they
expect u, so without this a touch near the edge of i becomes u.

Usage: tools/build_pinyin_letters.py <dict.tsv> <pinyin_char_trigram.bin>
"""
import collections
import math
import sys

N = 27
dict_path, out_path = sys.argv[1:]
counts = [0.0] * N ** 3
first = collections.Counter()
first_two = collections.Counter()
last = collections.Counter()
last_two = collections.Counter()


def add(a, b, c, weight):
    counts[(a * N + b) * N + c] += weight


for line in open(dict_path, encoding="utf8"):
    _, spelling, weight = line.rstrip("\n").split("\t")[:3]
    weight = max(float(weight), 1.0)
    letters = spelling.replace(" ", "")
    if not (letters.isascii() and letters.isalpha()):
        continue
    k = [ord(c) - 96 for c in letters]
    for i in range(2, len(k)):
        add(k[i - 2], k[i - 1], k[i], weight)
    first[k[0]] += weight
    last[k[-1]] += weight
    last_two[(k[-2] if len(k) >= 2 else 0, k[-1])] += weight
    if len(k) >= 2:
        first_two[(k[0], k[1])] += weight

for c, weight in first.items():
    add(0, 0, c, weight)
for (c, d), weight in first_two.items():
    add(0, c, d, weight)
first_total = sum(first.values())
first_two_total = sum(first_two.values())
for (y, z), weight in last_two.items():
    for c, share in first.items():
        add(y, z, c, weight * share / first_total)
for z, weight in last.items():
    for (c, d), share in first_two.items():
        add(z, c, d, weight * share / first_two_total)

out = bytearray(N ** 3)
for context in range(N * N):
    row = counts[context * N:(context + 1) * N]
    total = sum(row)
    for c in range(N):
        p = (row[c] + total * 1e-5 + 1e-9) / (total * (1 + N * 1e-5) + N * 1e-9)
        out[context * N + c] = min(255, round(-math.log2(p) * 16))
open(out_path, "wb").write(out)
