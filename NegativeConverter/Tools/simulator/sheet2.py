import numpy as np, sys, os
from PIL import Image, ImageDraw
D = sys.argv[1]; out = sys.argv[2]; TH = int(sys.argv[3]); names = sys.argv[4:]
rows = []
for n in names:
    raw = open(os.path.join(D, n + '.half'), 'rb').read()
    w, h = np.frombuffer(raw[:8], dtype=np.int32)
    neg = np.frombuffer(raw[8:], dtype=np.float16).reshape(h, w, 4)[..., :3].astype(np.float64)
    tiles = [Image.fromarray((np.clip(neg / max(np.percentile(neg, 99.9), 1e-6), 0, 1) ** (1 / 2.2) * 255).astype(np.uint8))]
    for kind in ('fit', 'trust'):
        tiles.append(Image.fromarray(np.frombuffer(open(os.path.join(D, f'{n}.{kind}.rgba'), 'rb').read(), dtype=np.uint8).reshape(h, w, 4)[..., :3]))
    rp = os.path.join(D, n + '.ref.png')
    if os.path.exists(rp): tiles.append(Image.open(rp).convert('RGB'))
    tiles = [t.resize((int(t.width * TH / t.height), TH), Image.LANCZOS) for t in tiles]
    W = sum(t.width for t in tiles) + 10 * len(tiles)
    row = Image.new('RGB', (W, TH + 18), (40, 40, 40)); x = 0
    for t in tiles: row.paste(t, (x, 18)); x += t.width + 10
    ImageDraw.Draw(row).text((4, 3), n + '   [negative | fit to picture | trust film exposure | original scene]', fill=(255, 255, 255))
    rows.append(row)
W = max(r.width for r in rows)
sheet = Image.new('RGB', (W, sum(r.height for r in rows)), (40, 40, 40)); y = 0
for r in rows: sheet.paste(r, (0, y)); y += r.height
sheet.save(out)
