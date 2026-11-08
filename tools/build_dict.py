#!/usr/bin/env python3
"""Builds dict.bin from the Android keyboard's dict.tsv and trade word lists.

The keyboard extension has little memory, so the dictionary is one read-only file mapped into
memory and nothing is parsed into objects. Little-endian, 4-byte aligned sections:

  header: "ZNDB", version, rows, syllables, words, dict.tsv rows, ln of all weights (f32),
  rows of two or more syllables
  text offsets (rows + 1, u32), syllable offsets (rows + 1, u32), word ids (rows, i32),
  scores (rows, f32), rows by text (rows, u32: for prefix searches), flags (rows, u8: 1 = trade
  word), syllable ids (u16), initials (u8), text (UTF-8), rows by 9-key code, best first (rows,
  u32), rows of two or more syllables by the code of their initials, best first (u32), syllable
  names (\\n-joined)

Rows are sorted by their initials, then best first, so a binary search finds the words for any
initials and the first match is the best. Word ids are distinct dict.tsv texts in file order, the
ids lm.bin was built for; trade words not in dict.tsv have id -1.

Usage: tools/build_dict.py <dict.tsv> <trade.tsv>... <dict.bin>
(trade.tsv is Android's, then tools/trade_extra.tsv and tools/chat_phrases.tsv.)
"""
import math
import struct
import sys

dict_path, *trade_paths, out_path = sys.argv[1:]
rows, ids, total = [], {}, 0.0
for line in open(dict_path, encoding="utf8"):
    text, spelling, weight = line.rstrip("\n").split("\t")[:3]
    weight = max(float(weight), 1.0)
    total += weight
    rows.append([text, spelling.split(" "), math.log(weight), ids.setdefault(text, len(ids)), 0, len(rows)])
dict_rows = len(rows)
known = {(r[0], " ".join(r[1])): r for r in rows}
spoken = {s for r in rows for s in r[1]}
for line in (line for path in trade_paths for line in open(path, encoding="utf8")):
    parts = line.rstrip("\n").split("\t")
    if len(parts) != 3 or not set(parts[1].split(" ")) <= spoken:
        continue
    if (parts[0], parts[1]) in known:
        known[(parts[0], parts[1])][4] = 1
    else:
        weight = max(float(parts[2]), 1.0)
        rows.append([parts[0], parts[1].split(" "), math.log(weight), -1, 1, len(rows)])

names = sorted({s for r in rows for s in r[1]})
index = {name: i for i, name in enumerate(names)}
rows.sort(key=lambda r: ("".join(s[0] for s in r[1]), -r[2], r[5]))

text_offsets, syllable_offsets, text, syllables, initials = [0], [0], bytearray(), [], bytearray()
for row in rows:
    text += row[0].encode("utf8")
    text_offsets.append(len(text))
    syllables += [index[s] for s in row[1]]
    initials += "".join(s[0] for s in row[1]).encode()
    syllable_offsets.append(len(syllables))

def pad(data):
    return bytes(data) + b"\0" * (-len(data) % 4)

KEYS = {letter: str(digit) for digit, letters in
        enumerate(("abc", "def", "ghi", "jkl", "mno", "pqrs", "tuv", "wxyz"), 2) for letter in letters}


def code(text):
    return "".join(KEYS[c] for c in text)


n = len(rows)
by_code = sorted(range(n), key=lambda i: (code("".join(rows[i][1])), -rows[i][2], rows[i][5]))
several = [i for i in range(n) if len(rows[i][1]) >= 2]
by_initials_code = sorted(several, key=lambda i: (code("".join(s[0] for s in rows[i][1])), -rows[i][2], rows[i][5]))
out = struct.pack("<4sIIIIIfI", b"ZNDB", 4, n, len(names), len(ids), dict_rows, math.log(total), len(several))
out += struct.pack(f"<{n + 1}I", *text_offsets)
out += struct.pack(f"<{n + 1}I", *syllable_offsets)
out += struct.pack(f"<{n}i", *[r[3] for r in rows])
out += struct.pack(f"<{n}f", *[r[2] for r in rows])
by_text = sorted(range(n), key=lambda i: (rows[i][0].encode("utf8"), -rows[i][2], rows[i][5]))
out += struct.pack(f"<{n}I", *by_text)
out += pad(bytes(r[4] for r in rows))
out += pad(struct.pack(f"<{len(syllables)}H", *syllables))
out += pad(initials)
out += pad(text)
out += struct.pack(f"<{n}I", *by_code)
out += struct.pack(f"<{len(several)}I", *by_initials_code)
out += "\n".join(names).encode()
open(out_path, "wb").write(out)
print(f"{n} rows, {len(names)} syllables, {len(ids)} words, {len(out) / 1e6:.1f} MB")
