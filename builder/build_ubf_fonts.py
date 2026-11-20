import struct
import glob
import os
import sys
from PIL import Image, ImageFont, ImageDraw

sys.stdout.reconfigure(encoding='utf-8')

def parse_ubf(path):
    with open(path, 'rb') as f:
        data = f.read()
    hdr = bytearray(data[:0x49])
    total_sz, s1_len, s2_len, s3_len = struct.unpack('<4I', hdr[0x18:0x28])
    s1_off = 0x49
    s2_off = s1_off + s1_len
    s3_off = s2_off + s2_len

    N = struct.unpack('<H', data[s1_off:s1_off+2])[0]
    end_codes = struct.unpack(f'<{N}H', data[s1_off+2 : s1_off+2+2*N])
    start_codes = struct.unpack(f'<{N}H', data[s1_off+4+2*N : s1_off+4+4*N])
    id_deltas = struct.unpack(f'<{N}i', data[s1_off+4+4*N : s1_off+4+8*N])

    num_glyphs = s2_len // 9
    glyphs = []
    for i in range(num_glyphs):
        g_off = s2_off + i * 9
        bh, bw, bx, by, ax, bmp_off = struct.unpack('<bbbBBI', data[g_off:g_off+9])
        row_bytes = (bw + 7) // 8
        bmp_len = bh * row_bytes
        bmp = data[s3_off + bmp_off : s3_off + bmp_off + bmp_len]
        glyphs.append((bh, bw, bx, by, ax, bmp))

    cp_to_glyph = {}
    for st, en, d in zip(start_codes, end_codes, id_deltas):
        if st == 0xFFFF and en == 0xFFFF:
            continue
        for cp in range(st, en + 1):
            g_idx = (cp + d) & 0xFFFF
            if 0 <= g_idx < len(glyphs):
                cp_to_glyph[cp] = glyphs[g_idx]

    return hdr, glyphs[0], cp_to_glyph

def render_char_glyph(ch: str, ttf_font: ImageFont.FreeTypeFont, target_cap_by: int, space_ax: int):
    if ch == ' ':
        return (0, 0, 0, 0, space_ax, b'')
    ascent, descent = ttf_font.getmetrics()
    # Measure 'A' top to align baseline exactly with existing font's cap height bearing_y
    img_A = Image.new('L', (64, 64), 0)
    draw_A = ImageDraw.Draw(img_A)
    draw_A.text((16, 16), 'A', fill=255, font=ttf_font)
    bbox_A = img_A.point(lambda p: 255 if p > 115 else 0).getbbox()
    baseline_y = bbox_A[3] if bbox_A else (16 + ascent)

    img = Image.new('L', (64, 64), 0)
    draw = ImageDraw.Draw(img)
    draw.text((16, 16), ch, fill=255, font=ttf_font)
    bw_img = img.point(lambda p: 255 if p > 115 else 0)
    bbox = bw_img.getbbox()
    ax = max(1, int(round(ttf_font.getlength(ch))))
    if not bbox:
        return (0, 0, 0, 0, ax, b'')
    x0, y0, x1, y1 = bbox
    bw = x1 - x0
    bh = y1 - y0
    bx = x0 - 16
    by = max(0, min(255, baseline_y - y0))
    row_bytes = (bw + 7) // 8
    bmp = bytearray()
    for r in range(bh):
        row_val = 0
        for c in range(bw):
            if bw_img.getpixel((x0 + c, y0 + r)) > 0:
                row_val |= (1 << (row_bytes * 8 - 1 - c))
        bmp.extend(row_val.to_bytes(row_bytes, 'big'))
    return (bh, bw, bx, by, ax, bytes(bmp))

def build_ubf(hdr: bytearray, glyph0, cp_to_glyph: dict) -> bytes:
    sorted_cps = sorted(cp for cp in cp_to_glyph.keys() if 0 < cp < 0xFFFF)
    glyph_list = [glyph0]
    start_codes = []
    end_codes = []
    id_deltas = []

    i = 0
    while i < len(sorted_cps):
        st = sorted_cps[i]
        en = st
        while i + 1 < len(sorted_cps) and sorted_cps[i + 1] == en + 1:
            en += 1
            i += 1
        base_g_idx = len(glyph_list)
        for cp in range(st, en + 1):
            glyph_list.append(cp_to_glyph[cp])
        delta = base_g_idx - st
        start_codes.append(st)
        end_codes.append(en)
        id_deltas.append(delta)
        i += 1

    # Add final 0xFFFF segment
    start_codes.append(0xFFFF)
    end_codes.append(0xFFFF)
    id_deltas.append(1)

    N = len(start_codes)
    s1 = bytearray()
    s1.extend(struct.pack('<H', N))
    s1.extend(struct.pack(f'<{N}H', *end_codes))
    s1.extend(struct.pack('<H', 0))  # reservedPad
    s1.extend(struct.pack(f'<{N}H', *start_codes))
    s1.extend(struct.pack(f'<{N}i', *id_deltas))

    s2 = bytearray()
    s3 = bytearray()
    for bh, bw, bx, by, ax, bmp in glyph_list:
        bmp_off = len(s3)
        s3.extend(bmp)
        s2.extend(struct.pack('<bbbBBI', bh, bw, bx, by, ax, bmp_off))

    s1_len = len(s1)
    s2_len = len(s2)
    s3_len = len(s3)
    total_sz = 0x49 + s1_len + s2_len + s3_len
    new_hdr = bytearray(hdr)
    new_hdr[0x18:0x28] = struct.pack('<4I', total_sz, s1_len, s2_len, s3_len)
    return bytes(new_hdr + s1 + s2 + s3)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))

def build_all_fonts():
    out_font_dir = os.path.join(BASE_DIR, 'out_patch', 'res', 'font')
    os.makedirs(out_font_dir, exist_ok=True)

    # Characters to ensure in every .ubf font:
    extra_cps = (
        list(range(0x20, 0x7F)) +           # Full printable ASCII (including ' ', 'j', etc.)
        [0x0401, 0x0451] +                  # Ё, ё
        list(range(0x0410, 0x0450)) +       # А..Я, а..я
        [0x00AB, 0x00BB, 0x2014, 0x2026, 0x2116]  # «, », —, …, №
    )

    for p in sorted(glob.glob(os.path.join(BASE_DIR, 'squashfs-root', 'app', 'bin', 'res', 'font', '*.ubf'))):
        fname = os.path.basename(p)
        hdr, glyph0, cp_to_glyph = parse_ubf(p)
        font_sz = hdr[0x31]
        is_bold = fname.endswith('b.ubf')
        ttf_path = r'C:\Windows\Fonts\arialbd.ttf' if is_bold else r'C:\Windows\Fonts\arial.ttf'
        # Match pixel height of existing 'A'
        orig_A = cp_to_glyph.get(ord('A'))
        target_cap_h = orig_A[0] if orig_A else int(font_sz * 0.75)
        # Find best ttf size whose 'A' height matches target_cap_h
        best_ttf = ImageFont.truetype(ttf_path, font_sz)
        for try_sz in range(font_sz - 3, font_sz + 5):
            f_try = ImageFont.truetype(ttf_path, try_sz)
            g_try = render_char_glyph('A', f_try, target_cap_h, font_sz // 2)
            if g_try[0] == target_cap_h:
                best_ttf = f_try
                break

        space_w = max(4, int(round(best_ttf.getlength(' '))))
        proportional_punct = set(b" .,;:!?'\"()-/")

        added = 0
        for cp in extra_cps:
            if cp not in cp_to_glyph or cp in proportional_punct:
                cp_to_glyph[cp] = render_char_glyph(chr(cp), best_ttf, target_cap_h, space_w)
                added += 1

        new_ubf = build_ubf(hdr, glyph0, cp_to_glyph)
        out_p = os.path.join(out_font_dir, fname)
        with open(out_p, 'wb') as f:
            f.write(new_ubf)
        print(f"Built {fname:14s}: orig={os.path.getsize(p):6d} B -> new={len(new_ubf):6d} B (added {added} glyphs)")


if __name__ == '__main__':
    build_all_fonts()
