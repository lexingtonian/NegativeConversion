# Copyright (C) 2025-2026 Ari Jaaksi. All rights reserved.
# Licensed under GPLv3 or a commercial license.
# See LICENSE.txt for details or contact [ari@slowlight.art] for commercial licensing.

import numpy as np, sys, os, glob
from PIL import Image, ImageDraw
D = sys.argv[1]; names = sys.argv[3:]; out = sys.argv[2]
TH = 300
rows = []
for n in names:
    raw = open(os.path.join(D, n + '.half'), 'rb').read()
    w, h = np.frombuffer(raw[:8], dtype=np.int32)
    neg = np.frombuffer(raw[8:], dtype=np.float16).reshape(h, w, 4)[..., :3].astype(np.float64)
    negv = np.clip(neg / 0.85, 0, 1) ** (1 / 2.2)
    pos = np.frombuffer(open(os.path.join(D, n + '.rgba'), 'rb').read(), dtype=np.uint8).reshape(h, w, 4)[..., :3]
    ref = Image.open(os.path.join(D, n + '.ref.png')).convert('RGB')
    tiles = [Image.fromarray((negv * 255).astype(np.uint8)), Image.fromarray(pos), ref]
    tiles = [t.resize((int(t.width * TH / t.height), TH), Image.LANCZOS) for t in tiles]
    W = sum(t.width for t in tiles) + 20
    row = Image.new('RGB', (W, TH + 18), (40, 40, 40))
    x = 0
    for t in tiles:
        row.paste(t, (x, 18)); x += t.width + 10
    ImageDraw.Draw(row).text((4, 3), n + '   [negative scan | converted | original scene]', fill=(255, 255, 255))
    rows.append(row)
W = max(r.width for r in rows)
sheet = Image.new('RGB', (W, sum(r.height for r in rows)), (40, 40, 40))
y = 0
for r in rows:
    sheet.paste(r, (0, y)); y += r.height
sheet.save(out)
