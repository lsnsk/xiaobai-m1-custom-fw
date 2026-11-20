import os
import struct

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
HIGV_IN  = os.path.join(BASE_DIR, "rootfs_435_extracted", "higv.bin")
HIGV_OUT = os.path.join(BASE_DIR, "out_patch_435", "higv.bin")
MAIN_OUT = os.path.join(BASE_DIR, "out_patch_435", "main_app")
LANG_RU  = os.path.join(BASE_DIR, "out_patch", "zh.lang")
FONT_DIR = os.path.join(BASE_DIR, "out_patch", "res", "font")


def crc32_mpeg2(data: bytes) -> int:
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= (b << 24)
        for _ in range(8):
            if crc & 0x80000000:
                crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF
            else:
                crc = (crc << 1) & 0xFFFFFFFF
    return crc


def parse_higv(buf: bytearray):
    tree_count, = struct.unpack_from("<I", buf, 0x39C4)
    base_nodes = 0x39C8 + tree_count * 12
    trees = []
    for ti in range(tree_count):
        tid, toff, tsz = struct.unpack_from("<3I", buf, 0x39C8 + ti * 12)
        p = base_nodes + toff
        end_p = p + tsz
        cur = p + 12
        widgets = []
        while cur < end_p:
            rec_sz, w_cnt, mask_bytes = struct.unpack_from("<3I", buf, cur)
            mask_words = struct.unpack_from(f"<{mask_bytes // 4}I", buf, cur + 12)
            pop = sum(bin(m).count("1") for m in mask_words)
            assert pop == w_cnt
            type_words = (pop + 3) // 4
            dyn_off = cur + 12 + mask_bytes + type_words * 4
            avail = (cur + rec_sz - dyn_off) // 4
            n_read = min(pop, avail)
            dyn_vals = list(struct.unpack_from(f"<{n_read}i", buf, dyn_off))
            fmap = {}
            foff = {}
            vi = 0
            for mwi, mw in enumerate(mask_words):
                for bit in range(32):
                    if mw & (1 << bit):
                        if vi < n_read:
                            bidx = mwi * 32 + bit
                            fmap[bidx] = dyn_vals[vi]
                            foff[bidx] = dyn_off + vi * 4
                        vi += 1
            widgets.append({
                "wid": fmap[1],
                "cls": fmap[0],
                "par": fmap.get(7, -1),
                "fmap": fmap,
                "foff": foff,
            })
            cur += rec_sz
        trees.append((ti, tid, widgets))
    return trees


def set_field(buf: bytearray, w: dict, bit: int, val: int):
    if val == 0 and bit not in w["foff"]:
        w["fmap"][bit] = 0
        return
    assert bit in w["foff"], f"wid={w['wid']} missing bit {bit} for non-zero val {val}"
    struct.pack_into("<i", buf, w["foff"][bit], int(val))
    w["fmap"][bit] = int(val)


def set_rect(buf: bytearray, w: dict, x=None, y=None, width=None, height=None):
    if x is not None:
        set_field(buf, w, 2, x)
    if y is not None:
        set_field(buf, w, 3, y)
    if width is not None:
        set_field(buf, w, 4, width)
    if height is not None:
        set_field(buf, w, 5, height)


def get_rect(w: dict):
    fm = w["fmap"]
    return fm.get(2, 0), fm.get(3, 0), fm.get(4, 0), fm.get(5, 0)


def _configure_home_dock_4btn(buf: bytearray, dock_h: int):
    """Repurpose wid=447 (Snap) & wid=454 (Record) into a 4-column Home dock inside wid=457."""
    trees = parse_higv(buf)
    _, tid18, ws18 = trees[18]
    assert tid18 == 441, f"Unexpected Tree 18 tid={tid18}"

    tree_count, = struct.unpack_from("<I", buf, 0x39C4)
    base_nodes = 0x39C8 + tree_count * 12
    tid, toff, tsz = struct.unpack_from("<3I", buf, 0x39C8 + 18 * 12)
    assert tid == 441
    p = base_nodes + toff
    end_p = p + tsz

    cur = p + 12
    records = []
    for w in ws18:
        rsz, = struct.unpack_from("<I", buf, cur)
        records.append((w["wid"], bytes(buf[cur:cur + rsz])))
        cur += rsz
    assert cur == end_p, f"Tree 18 size mismatch: {cur} != {end_p}"

    _ZERO12 = b'\x00' * 12

    def _make_rsz100(wid: int, x: int, y: int, str_off: int) -> bytes:
        """Build a 100-byte rsz=100/f1=13 widget record matching wid=458 layout.
        Layout: header(12) + mask(8) + types(16) + vals(52) + padding(12) = 100.
        extra field (tree index = 18) is inserted between h and par."""
        vals = struct.pack('<13i', 3, wid, x, y, 114, dock_h, 18, 457, 94, 11, str_off, 1028, 79)
        rec = struct.pack('<3I', 100, 13, 8)                                     # rsz, w_cnt, mask_bytes
        rec += struct.pack('<2I', 0x00E001FF, 0x00000400)                        # mask words
        rec += struct.pack('<4I', 0x00000300, 0x03000000, 0x00010303, 0x00000002)  # type words
        rec += vals
        rec += _ZERO12
        assert len(rec) == 100
        return rec

    orig_len = len(buf)
    # rsz=100 format (same as wid=458/459) → HiGV treats 447/454 as children of
    # wid=457 (dock container) → they get the same card background as «Записи»/«Настройки».
    rec_447 = _make_rsz100(447, 0, 0, 6966)
    rec_454 = _make_rsz100(454, 114, 0, 6974)

    reordered = []
    for wid, chunk in records:
        if wid in (447, 454):
            assert len(chunk) == 80, f"Unexpected wid={wid} record size {len(chunk)}"
            continue
        reordered.append(chunk)
        if wid == 457:
            reordered.extend((rec_447, rec_454))

    # blob is 40 bytes larger (2 × (100-80)) — update Tree 18 size in directory
    blob = b"".join(reordered)
    size_delta = len(blob) - (end_p - (p + 12))
    assert size_delta == 40, f"Expected +40 bytes, got {size_delta}"
    buf[p + 12:end_p] = blob  # bytearray slice assignment handles size change
    new_end_p = p + 12 + len(blob)

    # Update Tree 18 tsz in directory
    struct.pack_into("<I", buf, 0x39C8 + 18 * 12 + 8, tsz + size_delta)

    # Shift toff for all trees after tree 18
    for ti in range(19, tree_count):
        old_toff, = struct.unpack_from("<I", buf, 0x39C8 + ti * 12 + 4)
        struct.pack_into("<I", buf, 0x39C8 + ti * 12 + 4, old_toff + size_delta)

    # Update higv.bin header section offsets/sizes shifted by +size_delta:
    # 0x70 = sz_trees, 0x74 = off_strpool (rel 0x50), 0x7C = total_payload_sz
    for hoff in (0x70, 0x74, 0x7C):
        old_v, = struct.unpack_from("<I", buf, hoff)
        struct.pack_into("<I", buf, hoff, old_v + size_delta)

    assert len(buf) == orig_len + 40

    trees = parse_higv(buf)
    by_id = {w["wid"]: w for _, _, ws in trees for w in ws}
    set_rect(buf, by_id[458], 228, 0, 114, dock_h)
    set_field(buf, by_id[458], 21, 11)
    set_rect(buf, by_id[459], 342, 0, 114, dock_h)
    set_field(buf, by_id[459], 21, 11)
    return trees, by_id


def set_skin_colors(buf: bytearray, skin_id: int, bg_argb: int = None, fg_argb: int = None):
    assert 19 <= skin_id <= 270, f"Invalid skin_id {skin_id}"
    off = 0x0184 + (skin_id - 19) * 56
    sid, bg_type = struct.unpack_from("<2I", buf, off)
    assert sid == skin_id, f"Skin ID mismatch at {hex(off)}: got {sid}, expected {skin_id}"
    if bg_argb is not None:
        assert bg_type == 0, f"Skin {skin_id} uses image bg (type={bg_type}), cannot set solid bg_argb"
        struct.pack_into("<I", buf, off + 40, bg_argb & 0xFFFFFFFF)
    if fg_argb is not None:
        struct.pack_into("<I", buf, off + 44, fg_argb & 0xFFFFFFFF)


def modernize_skin_palette(buf: bytearray):
    # Deep Slate screen surface (#0D131F)
    for sid in (19, 20, 127, 132):
        set_skin_colors(buf, sid, bg_argb=0xFF0D131F)
    set_skin_colors(buf, 20, fg_argb=0xFFCBD5E1)
    set_skin_colors(buf, 132, fg_argb=0xFFCBD5E1)

    # High-contrast crisp off-white primary labels (#F1F5F9 instead of dull #A1A3A9)
    for sid in (30, 35, 94):
        set_skin_colors(buf, sid, fg_argb=0xFFF1F5F9)

    # Readable cool-slate secondary headers & right-aligned values (#94A3B8 instead of dim #5B5E6A)
    for sid in (33, 36, 40, 93):
        set_skin_colors(buf, sid, fg_argb=0xFF94A3B8)

    # Crisp pure-white / slate-white text on modal & primary buttons
    for sid in (207, 211, 216, 217):
        set_skin_colors(buf, sid, fg_argb=0xFFE2E8F0)
    for sid in (208, 212, 218, 219, 220):
        set_skin_colors(buf, sid, fg_argb=0xFFFFFFFF)

    # Modern dark-slate toast text (#F8FAFC on #1E293B toast pill)
    set_skin_colors(buf, 270, fg_argb=0xFFF8FAFC)


def verify_russian_text_widths(buf: bytearray, trees, skip_trees: set):
    if not os.path.isfile(LANG_RU) or not os.path.isdir(FONT_DIR):
        return
    from build_lang_files import read_lang
    from build_ubf_fonts import parse_ubf

    _, _, _, ru = read_lang(LANG_RU)
    pool_off = 0x50 + struct.unpack_from("<I", buf, 0x74)[0]
    pool = bytes(buf[pool_off:])

    def pool_str(off: int) -> str:
        if off <= 0 or off >= len(pool):
            return ""
        e = pool.find(b"\x00", off)
        return pool[off:e].decode("utf-8", errors="replace") if e >= 0 else ""

    # Map Font IDs 10..18 from 0x0088..0x0184
    font_glyphs = {}
    for i in range(9):
        fid, path_off = struct.unpack_from("<2I", buf, 0x0088 + i * 28)
        fn = os.path.basename(pool_str(path_off))
        fp = os.path.join(FONT_DIR, fn)
        if os.path.isfile(fp):
            _, _, cp_map = parse_ubf(fp)
            font_glyphs[fid] = cp_map

    def measure_px(text: str, fid: int) -> int:
        cp_map = font_glyphs.get(fid)
        if not cp_map:
            return 0
        return sum(cp_map.get(ord(ch), (0, 0, 0, 0, 10, b""))[4] for ch in text)

    # Skip unused legacy 320x240 / action-cam subtrees embedded inside Tree 26
    legacy_wids = set(range(536, 582))
    overflows = []
    for ti, tid, ws in trees:
        if ti in skip_trees:
            continue
        for w in ws:
            wid = w["wid"]
            if wid in legacy_wids:
                continue
            fm = w["fmap"]
            if 22 not in fm or 21 not in fm:
                continue
            s = pool_str(fm[22])
            if not (s.isdigit() and 0 < int(s) < len(ru)):
                continue
            txt = ru[int(s)]
            fid = fm[21]
            _, _, ww, hh = get_rect(w)
            if ww <= 4 or hh <= 4:
                continue
            px = measure_px(txt, fid)
            if px > ww:
                overflows.append((ti, wid, int(s), txt, px, ww))

    # Also verify worst-case dynamic runtime strings (live IP, SD usage, sleep timer)
    by_id = {w["wid"]: w for _, _, ws in trees for w in ws}
    dynamic_checks = [
        (720, 12, "4.3.5 (192.168.100.250)"),
        (717, 12, "04:CF:8C:AB:CD:EF"),
        (696, 12, "59.48G / 59.48G"),
        (649, 12, "Через 600 сек"),
    ]
    for wid, fid, sample in dynamic_checks:
        _, _, ww, _ = get_rect(by_id[wid])
        px = measure_px(sample, fid)
        if px > ww:
            overflows.append((-1, wid, -1, sample, px, ww))

    assert not overflows, f"Text pixel-width overflows detected: {overflows}"


def build_portrait_higv(out_path: str = HIGV_OUT):
    with open(HIGV_IN, "rb") as f:
        buf = bytearray(f.read())

    assert struct.unpack_from("<I", buf, 0)[0] == crc32_mpeg2(buf[4:]), "Input higv.bin CRC mismatch"
    modernize_skin_palette(buf)

    trees = parse_higv(buf)
    by_id = {w["wid"]: w for _, _, ws in trees for w in ws}

    skip_trees = {14, 15, 16, 17, 22}  # 1920x1080 video OSDs & 320x240 sub-view

    # 1. Generic pass for 854x480 full-screen roots, full-width backgrounds & headers
    for ti, tid, ws in trees:
        if ti in skip_trees:
            continue
        for w in ws:
            x, y, ww, hh = get_rect(w)
            if x == 0 and y == 0 and ww == 854 and hh == 480:
                set_rect(buf, w, 0, 0, 480, 854)
            elif x == 0 and y == 0 and ww == 854 and hh in (30, 48, 60, 80):
                set_rect(buf, w, 0, 0, 480, hh)

    # 2. Per-tree surgical layout & UX polish for 480x854 portrait
    # Tree 0 (271): Main menu ScrollGrid
    set_rect(buf, by_id[276], 0, 60, 480, 794)

    # Toast notifications (Trees 1, 2, 19, 20, 24, 30): wide 448x60 centered pills, zero clipping
    for wid in (278, 279, 281, 282, 463, 465, 524, 621, 622):
        set_rect(buf, by_id[wid], 16, 397, 448, 60)

    # Centered loading spinners & progress overlays
    set_rect(buf, by_id[284], 190, 377, 100, 100)
    set_rect(buf, by_id[293], 160, 379, 160, 96)
    set_rect(buf, by_id[792], 210, 367, 60, 60)
    set_rect(buf, by_id[793], 0, 437, 480, 40)

    # Confirmation Alert Modals: Trees 6 (Format SD), 8 (Full Reset), 12 (UI Reset), 38 (Unsupported SD)
    # Spacious 432x212 card centered at (24, 321) with 180x56 buttons matching button_4/button_5 1:1
    for card_wid, title_wid, sub_wid, btn_l, btn_r in (
        (297, 298, 299, 300, 301),
        (327, 328, 329, 330, 331),
        (368, 369, 370, 371, 372),
        (786, 787, 788, 789, 790),
    ):
        set_rect(buf, by_id[card_wid], 24, 321, 432, 212)
        set_rect(buf, by_id[title_wid], 0, 20, 432, 38)
        set_rect(buf, by_id[sub_wid], 0, 66, 432, 38)
        set_field(buf, by_id[sub_wid], 8, 36)   # secondary slate text
        set_field(buf, by_id[sub_wid], 21, 11)  # 20px subtitle font
        set_rect(buf, by_id[btn_l], 24, 134, 180, 56)
        set_rect(buf, by_id[btn_r], 228, 134, 180, 56)

    # Tree 4 (285): Modal 448x422 centered at (16, 216)
    set_rect(buf, by_id[286], 0, 0, 480, 216)
    set_rect(buf, by_id[287], 0, 638, 480, 216)
    set_rect(buf, by_id[288], 0, 216, 16, 422)
    set_rect(buf, by_id[289], 464, 216, 16, 422)
    set_rect(buf, by_id[290], 16, 216, 448, 422)
    set_rect(buf, by_id[291], 0, 0, 448, 64)

    # Tree 7 (302), Tree 13 (373), Tree 28 (608): Album date list & file grid
    set_rect(buf, by_id[306], 68, 0, 150, 60)
    set_rect(buf, by_id[307], 224, 0, 240, 60)
    set_field(buf, by_id[307], 23, 1026)  # right-align 'На MicroSD' badge
    set_field(buf, by_id[307], 8, 36)
    set_rect(buf, by_id[309], 474, 60, 6, 794)
    set_rect(buf, by_id[310], 0, 60, 480, 794)
    # 310 grid: 4 rows x 2 cols, symmetrical margins (48 + 160 + 64 + 160 + 48 = 480)
    set_field(buf, by_id[310], 55, 4)
    set_field(buf, by_id[310], 56, 2)
    set_field(buf, by_id[310], 64, 48)
    set_field(buf, by_id[310], 66, 64)

    # Tree 13 header (Back / Записи / Дата записи / На MicroSD)
    set_rect(buf, by_id[377], 64, 0, 104, 60)
    set_rect(buf, by_id[378], 170, 0, 160, 60)
    set_rect(buf, by_id[379], 332, 0, 134, 60)
    set_field(buf, by_id[379], 23, 1026)  # right-align 'На MicroSD'
    set_field(buf, by_id[379], 8, 36)
    set_rect(buf, by_id[380], 0, 0, 168, 60)
    set_rect(buf, by_id[381], 474, 60, 6, 794)
    set_rect(buf, by_id[382], 0, 60, 480, 794)
    # 382 grid: 3 rows x 2 cols, symmetrical 6px margins (6 + 231 + 6 + 231 + 6 = 480)
    set_field(buf, by_id[382], 55, 3)
    set_field(buf, by_id[382], 56, 2)
    set_field(buf, by_id[382], 64, 6)
    set_field(buf, by_id[382], 66, 6)

    # No-MicroSD instruction block in Trees 7, 13, 28 (fix vertical overlap on lines 2 & 3)
    for box_id, ic_id, ttl_id, l1_id, l2_id, l3_id in (
        (314, 315, 316, 317, 318, 319),
        (388, 389, 390, 391, 392, 393),
        (613, 614, 615, 616, 617, 618),
    ):
        set_rect(buf, by_id[box_id], 15, 290, 450, 240)
        set_rect(buf, by_id[ic_id], 185, 0, 80, 80)
        set_rect(buf, by_id[ttl_id], 0, 88, 450, 38)
        set_rect(buf, by_id[l1_id], 0, 134, 450, 32)
        set_rect(buf, by_id[l2_id], 0, 168, 450, 32)
        set_rect(buf, by_id[l3_id], 0, 202, 450, 32)

    for wid, ic_id, lbl_id in ((320, 321, 322), (394, 395, 396)):
        set_rect(buf, by_id[wid], 16, 302, 448, 250)
        set_rect(buf, by_id[ic_id], 184, 0, 80, 80)
        set_rect(buf, by_id[lbl_id], 0, 88, 448, 44)

    # Empty album state ('Нет видеозаписей' widened from 100px to 280px so text never clips)
    for box_id, ic_id, lbl_id in ((323, 324, 325), (397, 398, 399)):
        set_rect(buf, by_id[box_id], 100, 360, 280, 124)
        set_rect(buf, by_id[ic_id], 100, 0, 80, 80)
        set_rect(buf, by_id[lbl_id], 0, 84, 280, 40)

    # Tree 10 (338): 3-option modal 448x282 at (16, 286)
    set_rect(buf, by_id[339], 0, 0, 480, 286)
    set_rect(buf, by_id[340], 0, 568, 480, 286)
    set_rect(buf, by_id[341], 0, 286, 16, 282)
    set_rect(buf, by_id[342], 464, 286, 16, 282)
    set_rect(buf, by_id[343], 16, 286, 448, 282)
    set_rect(buf, by_id[344], 0, 0, 448, 64)
    set_rect(buf, by_id[345], 16, 286, 448, 282)
    set_field(buf, by_id[345], 8, 43)  # Transparent container so 345 never paints over title 344
    for wid in (346, 347, 348):
        _, y, _, hh = get_rect(by_id[wid])
        set_rect(buf, by_id[wid], 16, y, 416, hh)
        set_field(buf, by_id[wid], 23, 1028)  # Center option labels cleanly

    # Tree 11 (349): Scrollable Auto-Sleep selection modal 448x420 at (16, 217)
    set_rect(buf, by_id[350], 0, 0, 480, 217)
    set_rect(buf, by_id[351], 0, 637, 480, 217)
    set_rect(buf, by_id[352], 0, 217, 16, 420)
    set_rect(buf, by_id[353], 464, 217, 16, 420)
    set_rect(buf, by_id[354], 16, 217, 448, 62)
    set_rect(buf, by_id[355], 16, 217, 448, 64)
    set_rect(buf, by_id[356], 16, 549, 448, 88)
    set_rect(buf, by_id[357], 28, 563, 204, 60)
    set_rect(buf, by_id[358], 248, 563, 204, 60)
    set_rect(buf, by_id[359], 458, 279, 6, 270)
    set_rect(buf, by_id[360], 16, 279, 448, 270)
    for wid in range(361, 367):
        _, y, _, hh = get_rect(by_id[wid])
        set_rect(buf, by_id[wid], 16, y, 416, hh)
        set_field(buf, by_id[wid], 23, 1028)  # Center option labels cleanly

    # Tree 18 (441): Live Camera Home Screen (34px top scrim + 456x76 4-btn floating glass dock)
    set_rect(buf, by_id[443], 0, 0, 480, 34)
    for wid in (444, 446, 449, 450, 451):
        x, y, ww, hh = get_rect(by_id[wid])
        ny = y + 2 if y >= 0 else y
        set_rect(buf, by_id[wid], x - 374, ny, ww, hh)
    set_rect(buf, by_id[445], 12, 2, 280, 30)
    set_rect(buf, by_id[452], 0, 818, 480, 36)
    set_rect(buf, by_id[456], 444, 0, 32, 0)
    set_rect(buf, by_id[457], 12, 728, 456, 76)
    trees, by_id = _configure_home_dock_4btn(buf, 76)
    set_rect(buf, by_id[460], 216, 403, 48, 48)
    set_rect(buf, by_id[461], 160, 367, 160, 120)

    # Tree 23 (506): Video/Photo Playback Screen (ergonomic 72px bottom transport bar)
    for wid in (510, 511, 515):
        x, y, ww, hh = get_rect(by_id[wid])
        set_rect(buf, by_id[wid], x - 374, y, ww, hh)
    set_rect(buf, by_id[513], 20, 803, 30, 30)
    set_rect(buf, by_id[514], 0, 782, 72, 72)
    set_rect(buf, by_id[518], 66, 782, 64, 72)
    set_rect(buf, by_id[520], 132, 782, 216, 72)
    set_rect(buf, by_id[519], 350, 782, 64, 72)
    set_rect(buf, by_id[516], 408, 782, 72, 72)
    set_rect(buf, by_id[517], 430, 803, 30, 30)
    set_rect(buf, by_id[521], 385, 570, 80, 180)
    set_rect(buf, by_id[522], 32, 110, 416, 656)

    # Tree 25 (525) & Tree 26 (532)
    for wid in (529, 530, 531):
        _, y, _, hh = get_rect(by_id[wid])
        set_rect(buf, by_id[wid], 0, y, 480, hh)
    set_rect(buf, by_id[533], 110, 367, 260, 120)
    set_rect(buf, by_id[557], 60, 0, 360, 48)

    # Tree 27 (582): 5-icon horizontal selector with 96px columns & 16px caption font so zero labels clip
    set_rect(buf, by_id[583], 0, 0, 480, 64)
    set_rect(buf, by_id[584], 20, 17, 30, 30)
    set_rect(buf, by_id[585], 71, 0, 260, 64)
    set_rect(buf, by_id[592], 0, 80, 480, 280)
    set_rect(buf, by_id[586], 0, 410, 480, 140)
    for idx, wid in enumerate((587, 588, 589, 590, 591)):
        set_rect(buf, by_id[wid], idx * 96, 0, 96, 140)
        set_field(buf, by_id[wid], 21, 10)  # 16px caption font
    for idx, base_wid in enumerate((593, 596, 599, 602, 605)):
        bx = 3 + idx * 96
        set_rect(buf, by_id[base_wid], bx, 0, 90, 92)
        set_rect(buf, by_id[base_wid + 1], bx + 15, 0, 60, 60)
        set_rect(buf, by_id[base_wid + 2], bx, 64, 90, 26)

    # Tree 31 (623): Settings Listbox
    set_rect(buf, by_id[624], 0, 0, 480, 60)
    set_rect(buf, by_id[625], 0, 0, 72, 60)
    set_rect(buf, by_id[626], 120, 0, 240, 60)
    set_rect(buf, by_id[627], 475, 62, 3, 790)
    set_rect(buf, by_id[628], 475, 60, 3, 2)
    set_rect(buf, by_id[629], 478, 60, 2, 794)
    set_rect(buf, by_id[630], 475, 852, 3, 2)
    set_rect(buf, by_id[631], 0, 60, 475, 794)
    set_field(buf, by_id[631], 90, 310)

    # Settings Header Prev/Next Pill Buttons across Trees 32, 33, 34
    for wid in (641, 680, 709):
        set_rect(buf, by_id[wid], 0, 0, 240, 60)
    for wid in (642, 643, 644, 681, 682, 683, 684, 710, 711, 712):
        x, y, ww, hh = get_rect(by_id[wid])
        set_rect(buf, by_id[wid], x - 374, y, ww, hh)

    # Helper to align x=0 section headers (646, 652, 666, 686, 714) flush to x=30 (card inner margin)
    from build_lang_files import read_lang
    from build_ubf_fonts import parse_ubf
    _, _, _, _ru_sec = read_lang(LANG_RU)
    _, _, _f11_map = parse_ubf(os.path.join(FONT_DIR, "nomal-20.ubf"))

    def align_section_header(box_wid: int, lbl_wid: int, y_pos: int, lang_idx: int):
        px_w = sum(_f11_map.get(ord(c), (0, 0, 0, 0, 10, b""))[4] for c in _ru_sec[lang_idx])
        target_w = 30 + px_w
        set_rect(buf, by_id[box_wid], 0, y_pos, max(260, target_w + 16), 36)
        set_rect(buf, by_id[lbl_wid], 0, 0, target_w, 36)
        set_field(buf, by_id[lbl_wid], 23, 1026)  # vertical middle + right-align -> left edge at x=30!

    # Tree 32 (637): Settings Page 1 — Auto-Sleep, Volume (Indoor/Outdoor), Brightness (1:1 456x76 cards)
    align_section_header(645, 646, 88, 118)   # 'Сон'
    set_rect(buf, by_id[647], 12, 128, 456, 76)
    set_rect(buf, by_id[648], 18, 0, 210, 76)
    set_rect(buf, by_id[649], 228, 0, 178, 76)
    set_rect(buf, by_id[650], 414, 23, 30, 30)

    align_section_header(651, 652, 232, 119)  # 'Звук'
    set_rect(buf, by_id[653], 12, 272, 456, 76)
    set_rect(buf, by_id[659], 12, 362, 456, 76)

    align_section_header(665, 666, 466, 120)  # 'Яркость'
    set_rect(buf, by_id[667], 12, 506, 456, 76)

    for row_base in (653, 659, 667):
        set_rect(buf, by_id[row_base + 1], 18, 0, 136, 76)     # Wide 136px label ('В доме' / 'На двери' / 'Экран')
        set_rect(buf, by_id[row_base + 2], 168, 23, 30, 30)    # '-' circular button icon
        set_rect(buf, by_id[row_base + 3], 406, 23, 30, 30)    # '+' circular button icon
        set_rect(buf, by_id[row_base + 4], 152, 0, 62, 76)     # '-' generous 62x76 touch zone
        set_rect(buf, by_id[row_base + 5], 390, 0, 66, 76)     # '+' generous 66x76 touch zone

    set_rect(buf, by_id[673], 224, 307, 176, 6)
    set_rect(buf, by_id[674], 224, 397, 176, 6)
    set_rect(buf, by_id[675], 224, 541, 176, 6)

    # Tree 33 (676): Settings Page 2 — Eco Mode (1:1 456x132 card) & MicroSD Storage (1:1 456x76 cards)
    align_section_header(685, 686, 88, 122)   # 'Питание'
    set_rect(buf, by_id[687], 12, 128, 456, 132)
    set_rect(buf, by_id[688], 18, 12, 268, 56)
    set_rect(buf, by_id[689], 18, 82, 420, 36)
    set_rect(buf, by_id[690], 304, 138, 150, 60)  # Native 150x60 3-slice capsule
    set_rect(buf, by_id[691], 0, 0, 150, 60)
    set_rect(buf, by_id[692], 310, 144, 48, 48)   # Matches main_app OFF=(310,144), ON=(400,144)
    set_rect(buf, by_id[693], 324, 138, 110, 60)  # Centered inside 304..454 with 20px side padding

    set_rect(buf, by_id[694], 30, 288, 240, 36)
    set_field(buf, by_id[694], 23, 1025)          # Vertical middle + left-align at x=30
    set_rect(buf, by_id[695], 12, 328, 456, 76)
    set_rect(buf, by_id[696], 18, 0, 214, 76)
    set_rect(buf, by_id[697], 242, 35, 196, 6)

    set_rect(buf, by_id[698], 12, 418, 456, 76)
    set_rect(buf, by_id[699], 18, 0, 212, 76)
    set_rect(buf, by_id[700], 426, 441, 30, 30)
    set_rect(buf, by_id[701], 12, 418, 456, 76)   # Full-row touch target
    set_rect(buf, by_id[702], 242, 418, 178, 76)
    set_field(buf, by_id[702], 21, 11)            # 20px secondary badge font
    set_field(buf, by_id[702], 8, 36)             # Cool-slate status color
    set_field(buf, by_id[702], 23, 1026)          # Right-align 'Нет карты'
    set_rect(buf, by_id[703], 242, 418, 178, 76)
    set_field(buf, by_id[703], 21, 11)            # 20px secondary badge font
    set_field(buf, by_id[703], 8, 36)             # Cool-slate status color
    set_field(buf, by_id[703], 23, 1026)          # Right-align 'Неверный формат'
    set_rect(buf, by_id[704], 12, 418, 456, 76)   # Full-row touch target

    # Tree 34 (705): Settings Page 3 — System Info (Live IP!), Screen Reset & Full Reset (1:1 456x76 cards)
    align_section_header(713, 714, 88, 124)   # 'О системе'

    about_rows = (
        (715, 716, 130, 717, 154, 284),  # MAC
        (718, 719, 116, 720, 140, 298),  # ПО / IP (298px wide for '4.3.5 (192.168.xxx.xxx)')
        (721, 722, 220, 723, 244, 194),  # Заряд батареи
        (724, 725, 384, 726, 414,  30),  # Сброс настроек экрана
        (727, 728, 384, 729, 414,  30),  # Полный сброс устройства
    )
    for idx, (rwid, lwid, lw, vwid, vx, vw) in enumerate(about_rows):
        ry = 128 + idx * 88
        set_rect(buf, by_id[rwid], 12, ry, 456, 76)
        set_rect(buf, by_id[lwid], 18, 0, lw, 76)
        if vwid in (726, 729):
            set_rect(buf, by_id[vwid], vx, 23, vw, 30)
        else:
            set_rect(buf, by_id[vwid], vx, 0, vw, 76)

    # Secret multi-tap zones aligned 1:1 with rows 715, 718, 721
    set_rect(buf, by_id[730], 12, 128, 224, 76)
    set_rect(buf, by_id[731], 244, 128, 224, 76)
    set_rect(buf, by_id[732], 12, 216, 224, 76)
    set_rect(buf, by_id[733], 244, 216, 224, 76)
    set_rect(buf, by_id[734], 12, 304, 456, 76)

    # Tree 35 (735): Spacious 2-column portrait engineering diagnostic menu (zero squished labels)
    set_rect(buf, by_id[737], 16, 19, 40, 42)
    set_rect(buf, by_id[738], 66, 0, 260, 80)
    set_rect(buf, by_id[739], 330, 15, 138, 50)
    set_rect(buf, by_id[740], 16, 92, 220, 46)
    set_rect(buf, by_id[741], 16, 138, 220, 46)
    set_rect(buf, by_id[742], 244, 92, 220, 46)
    set_rect(buf, by_id[743], 244, 138, 220, 46)
    set_rect(buf, by_id[744], 16, 196, 220, 46)
    set_rect(buf, by_id[745], 16, 242, 220, 46)
    set_rect(buf, by_id[746], 244, 196, 220, 92)
    set_rect(buf, by_id[747], 244, 196, 220, 46)
    set_rect(buf, by_id[748], 244, 242, 220, 46)
    for row_idx, (lbl_id, val_id) in enumerate(((749, 750), (755, 756), (751, 752), (753, 754))):
        ry = 308 + row_idx * 68
        set_rect(buf, by_id[lbl_id], 16, ry, 220, 56)
        set_rect(buf, by_id[val_id], 244, ry, 220, 56)
    set_rect(buf, by_id[757], 16, 604, 448, 58)
    for idx, wid in enumerate((758, 759, 760, 761, 762, 763)):
        col = idx % 3
        row = idx // 3
        set_rect(buf, by_id[wid], 16 + col * 152, 680 + row * 70, 144, 58)

    # Tree 37 (768): 4-quadrant screen border test scaled to 480x854
    for wid in range(769, 785):
        x, y, ww, hh = get_rect(by_id[wid])
        nx = round(x * 480 / 854)
        nx2 = round((x + ww) * 480 / 854)
        ny = round(y * 854 / 480)
        ny2 = round((y + hh) * 854 / 480)
        set_rect(buf, by_id[wid], nx, ny, max(10, nx2 - nx), max(10, ny2 - ny))

    # Recompute MPEG-2 CRC32 over buf[4:]
    new_crc = crc32_mpeg2(buf[4:])
    struct.pack_into("<I", buf, 0, new_crc)

    # Verify zero bounds violations AND zero .ubf Russian text pixel overflows
    orig_trees = parse_higv(bytearray(open(HIGV_IN, "rb").read()))
    orig_by_id = {w["wid"]: w for _, _, ws in orig_trees for w in ws}
    verify_trees = parse_higv(buf)
    verify_by_id = {w["wid"]: w for _, _, ws in verify_trees for w in ws}
    violations = []
    for ti, tid, ws in verify_trees:
        if ti in skip_trees:
            continue
        for w in ws:
            wid = w["wid"]
            x, y, ww, hh = get_rect(w)
            _, oy, _, ohh = get_rect(orig_by_id[wid])
            par = w["par"]
            pw, ph = (480, 854)
            opw, oph = (854, 480)
            if par != wid and par in verify_by_id:
                _, _, pw, ph = get_rect(verify_by_id[par])
                _, _, opw, oph = get_rect(orig_by_id[par])
            if x < 0 or x + ww > pw or pw > 480 or (y + hh > ph and oy + ohh <= oph):
                violations.append((ti, wid, par, (x, y, ww, hh), (pw, ph)))

    assert not violations, f"Portrait UI bounds violations: {violations}"
    verify_russian_text_widths(buf, verify_trees, skip_trees)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(buf)
    print(f"Saved modern portrait {out_path} ({len(buf)} bytes, CRC={hex(new_crc)}, 0 bounds & 0 .ubf pixel-width overflows)")


def build_landscape_higv(out_path: str):
    """
    Build Modern Slate Dark 854x480 horizontal higv.bin for standard door mounting:
      - Applies modernize_skin_palette (#0D131F surface, #162032 1:1 cards, crisp slate typography)
      - Fixes all 20 Russian text pixel-width overflows & stock OOB rects on 854x480
      - Aligns 1:1 with 814x60 / 814x90 cards, 456x64 floating glass dock, and 432x212 alert modals
    """
    with open(HIGV_IN, "rb") as f:
        buf = bytearray(f.read())

    assert struct.unpack_from("<I", buf, 0)[0] == crc32_mpeg2(buf[4:]), "Input higv.bin CRC mismatch"
    modernize_skin_palette(buf)

    trees = parse_higv(buf)
    by_id = {w["wid"]: w for _, _, ws in trees for w in ws}
    skip_trees = {14, 15, 16, 17, 22}

    # 1. Toast notifications (Trees 1, 2, 19, 20, 24, 30): wide 520x60 centered pills at (167, 210)
    for wid in (278, 279, 281, 282, 463, 465, 524, 621, 622):
        set_rect(buf, by_id[wid], 167, 210, 520, 60)

    # 2. Confirmation Alert Modals: Trees 6 (Format SD), 8 (Full Reset), 12 (UI Reset), 38 (Unsupported SD)
    #    Spacious 432x212 card centered at (211, 134) with 180x56 buttons matching button_4/button_5 1:1
    for card_wid, title_wid, sub_wid, btn_l, btn_r in (
        (297, 298, 299, 300, 301),
        (327, 328, 329, 330, 331),
        (368, 369, 370, 371, 372),
        (786, 787, 788, 789, 790),
    ):
        set_rect(buf, by_id[card_wid], 211, 134, 432, 212)
        set_rect(buf, by_id[title_wid], 0, 20, 432, 38)
        set_rect(buf, by_id[sub_wid], 0, 66, 432, 38)
        set_field(buf, by_id[sub_wid], 8, 36)   # secondary slate text
        set_field(buf, by_id[sub_wid], 21, 11)  # 20px subtitle font
        set_rect(buf, by_id[btn_l], 24, 134, 180, 56)
        set_rect(buf, by_id[btn_r], 228, 134, 180, 56)

    # 3. Album headers, No-MicroSD instructions & Empty Album state (Trees 7, 13, 28)
    set_rect(buf, by_id[307], 594, 0, 240, 60)
    set_field(buf, by_id[307], 23, 1026)  # right-align 'На MicroSD' badge
    set_field(buf, by_id[307], 8, 36)
    set_rect(buf, by_id[379], 634, 0, 200, 60)
    set_field(buf, by_id[379], 23, 1026)
    set_field(buf, by_id[379], 8, 36)

    for box_id, ic_id, ttl_id, l1_id, l2_id, l3_id in (
        (314, 315, 316, 317, 318, 319),
        (388, 389, 390, 391, 392, 393),
        (613, 614, 615, 616, 617, 618),
    ):
        set_rect(buf, by_id[box_id], 202, 130, 450, 234)
        set_rect(buf, by_id[ic_id], 185, 0, 80, 80)
        set_rect(buf, by_id[ttl_id], 0, 86, 450, 38)
        set_rect(buf, by_id[l1_id], 0, 130, 450, 32)
        set_rect(buf, by_id[l2_id], 0, 164, 450, 32)
        set_rect(buf, by_id[l3_id], 0, 198, 450, 32)

    for box_id, ic_id, lbl_id in ((323, 324, 325), (397, 398, 399)):
        set_rect(buf, by_id[box_id], 287, 184, 280, 124)
        set_rect(buf, by_id[ic_id], 100, 0, 80, 80)
        set_rect(buf, by_id[lbl_id], 0, 84, 280, 40)

    # 4. Option Modals in Trees 10 (620x282) & 11 (620x420): transparent container + centered option pills
    set_rect(buf, by_id[344], 0, 0, 620, 64)
    set_field(buf, by_id[345], 8, 43)  # Transparent container so 345 never paints over title 344
    for wid in (346, 347, 348):
        set_field(buf, by_id[wid], 23, 1028)
    for wid in range(361, 367):
        set_field(buf, by_id[wid], 23, 1028)

    # 5. Tree 18 (441): Live Camera Home Screen (34px top scrim + 456x64 4-btn floating glass dock centered at x=199)
    set_rect(buf, by_id[443], 0, 0, 854, 34)
    for wid in (444, 446, 449, 450, 451):
        x, y, ww, hh = get_rect(by_id[wid])
        ny = y + 2 if y >= 0 else y
        set_rect(buf, by_id[wid], x, ny, ww, hh)
    set_rect(buf, by_id[445], 12, 2, 300, 30)
    set_rect(buf, by_id[452], 0, 448, 854, 32)
    set_rect(buf, by_id[457], 199, 398, 456, 64)
    trees, by_id = _configure_home_dock_4btn(buf, 64)

    # 6. Tree 27 (582): 5-icon horizontal selector with 156px columns across 854px (37 + 5*156 + 37 = 854)
    set_rect(buf, by_id[585], 71, 0, 260, 60)
    for idx, wid in enumerate((587, 588, 589, 590, 591)):
        set_rect(buf, by_id[wid], 37 + idx * 156, 0, 156, 130)

    # 7. Settings Pages 1–3 (Trees 32, 33, 34) — 814x60 & 814x90 cards at x=20..834
    from build_lang_files import read_lang
    from build_ubf_fonts import parse_ubf
    _, _, _, _ru_sec = read_lang(LANG_RU)
    _, _, _f11_map = parse_ubf(os.path.join(FONT_DIR, "nomal-20.ubf"))

    def align_section_header_land(box_wid: int, lbl_wid: int, y_pos: int, lang_idx: int):
        px_w = sum(_f11_map.get(ord(c), (0, 0, 0, 0, 10, b""))[4] for c in _ru_sec[lang_idx])
        target_w = 40 + px_w
        set_rect(buf, by_id[box_wid], 0, y_pos, max(280, target_w + 16), 30)
        set_rect(buf, by_id[lbl_wid], 0, 0, target_w, 30)
        set_field(buf, by_id[lbl_wid], 23, 1026)  # vertical middle + right-align -> left edge flush at x=40!

    # Tree 32 (Page 1): Auto-Sleep, Volume (Indoor/Outdoor), Brightness
    align_section_header_land(645, 646, 76, 118)   # 'Сон'
    set_rect(buf, by_id[648], 20, 0, 260, 60)
    set_rect(buf, by_id[649], 514, 0, 240, 60)

    align_section_header_land(651, 652, 184, 119)  # 'Звук'
    align_section_header_land(665, 666, 364, 120)  # 'Яркость'
    for lbl_wid in (654, 660, 668):
        set_rect(buf, by_id[lbl_wid], 20, 0, 220, 60)

    # Tree 33 (Page 2): Eco Mode (814x90 at (20, 108), stock knob (656/746, 129)) & MicroSD Storage
    align_section_header_land(685, 686, 76, 122)   # 'Питание'
    set_rect(buf, by_id[688], 20, 10, 320, 42)
    set_field(buf, by_id[688], 23, 1025)
    set_rect(buf, by_id[689], 20, 50, 590, 32)
    set_field(buf, by_id[689], 23, 1025)
    set_rect(buf, by_id[693], 670, 123, 110, 60)

    set_rect(buf, by_id[694], 40, 214, 260, 30)
    set_field(buf, by_id[694], 23, 1025)
    set_rect(buf, by_id[701], 20, 318, 814, 60)
    set_rect(buf, by_id[702], 490, 318, 284, 60)
    set_field(buf, by_id[702], 21, 11)
    set_field(buf, by_id[702], 8, 36)
    set_field(buf, by_id[702], 23, 1026)
    set_rect(buf, by_id[703], 490, 318, 284, 60)
    set_field(buf, by_id[703], 21, 11)
    set_field(buf, by_id[703], 8, 36)
    set_field(buf, by_id[703], 23, 1026)
    set_rect(buf, by_id[704], 20, 318, 814, 60)

    # Tree 34 (Page 3): System Info (Live IP!), Screen Reset & Full Reset
    align_section_header_land(713, 714, 75, 124)   # 'О системе'
    set_rect(buf, by_id[716], 20, 0, 240, 60)
    set_rect(buf, by_id[717], 494, 0, 300, 60)
    set_rect(buf, by_id[719], 20, 0, 240, 60)
    set_rect(buf, by_id[720], 454, 0, 340, 60)     # 340px wide for '4.3.5 (192.168.100.250)'
    set_rect(buf, by_id[722], 20, 0, 260, 60)
    set_rect(buf, by_id[723], 554, 0, 240, 60)
    set_rect(buf, by_id[725], 20, 0, 480, 60)      # 'Сброс настроек экрана'
    set_rect(buf, by_id[728], 20, 0, 480, 60)      # 'Полный сброс устройства'
    set_rect(buf, by_id[734], 20, 247, 814, 60)

    # 8. Tree 35 (735): Engineering diagnostic menu title widened so 'Тест устройства' never clips
    set_rect(buf, by_id[738], 78, 0, 320, 80)

    # Recompute MPEG-2 CRC32 over buf[4:]
    new_crc = crc32_mpeg2(buf[4:])
    struct.pack_into("<I", buf, 0, new_crc)

    # Verify zero bounds violations inside 854x480 AND zero .ubf Russian text pixel overflows
    orig_trees = parse_higv(bytearray(open(HIGV_IN, "rb").read()))
    orig_by_id = {w["wid"]: w for _, _, ws in orig_trees for w in ws}
    verify_trees = parse_higv(buf)
    verify_by_id = {w["wid"]: w for _, _, ws in verify_trees for w in ws}
    violations = []
    for ti, tid, ws in verify_trees:
        if ti in skip_trees:
            continue
        for w in ws:
            wid = w["wid"]
            x, y, ww, hh = get_rect(w)
            _, oy, _, ohh = get_rect(orig_by_id[wid])
            par = w["par"]
            pw, ph = (854, 480)
            opw, oph = (854, 480)
            if par != wid and par in verify_by_id:
                _, _, pw, ph = get_rect(verify_by_id[par])
                _, _, opw, oph = get_rect(orig_by_id[par])
            if x < 0 or x + ww > pw or pw > 854 or (y + hh > ph and oy + ohh <= oph):
                violations.append((ti, wid, par, (x, y, ww, hh), (pw, ph)))

    assert not violations, f"Landscape UI bounds violations: {violations}"
    verify_russian_text_widths(buf, verify_trees, skip_trees)

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(buf)
    print(f"Saved modern landscape {out_path} ({len(buf)} bytes, CRC={hex(new_crc)}, 0 bounds & 0 .ubf pixel-width overflows)")


def patch_main_app_portrait(main_data: bytearray):
    def put_u32(va: int, val: int, expected: int = None):
        foff = va - 0x10000
        cur, = struct.unpack_from("<I", main_data, foff)
        if expected is not None:
            assert cur == expected, f"Mismatch at VA {hex(va)}: got {hex(cur)}, expected {hex(expected)}"
        struct.pack_into("<I", main_data, foff, val)

    # 1. PDT_UI_StartLCD: Canvas 480x854, RotateMode = 0 (HIGV_ROTATE_NONE)
    put_u32(0x3DFBC, 0xE3A01E1E, 0xE3001356)  # Width:  854 -> 480
    put_u32(0x3DFE8, 0xE3001356, 0xE3A01E1E)  # Height: 480 -> 854
    put_u32(0x3E040, 0xE3A01000, 0xE1A01005)  # RotateMode: 1 -> 0

    # 2. PDT_UI_ReadTouchData: 90 deg CW portrait touch mapping
    put_u32(0x3F564, 0xE3002355, 0xE3002356)  # 853 so out_y in 0..853
    put_u32(0x3F574, 0xE0633203, 0xE0433203)  # +15 * raw_x (then <<5 = +480 * raw_x)
    put_u32(0x3F58C, 0xE5842008, 0xE5842004)  # store out_y to [r4 + 8]
    put_u32(0x3F5A0, 0xE3530000, 0xE2833E1E)  # cmp out_x, #0
    put_u32(0x3F5A4, 0xB3A03000, 0xE3530E1E)  # if < 0: out_x = 0
    put_u32(0x3F5A8, 0xE3530E1E, 0x03520E1E)  # cmp out_x, #480
    put_u32(0x3F5AC, 0xA30031DF, 0x030031DF)  # if >= 480: out_x = 479
    put_u32(0x3F5B0, 0xE5843004, 0xE5843008)  # store out_x to [r4 + 4]

    # 3. PDT_UI_HOME_SendSpotMeteringMsg: 480x854 clamp & axis swap
    put_u32(0x3B3A8, 0xE30041C8, 0xE300433E)  # x max clamp: 830 -> 456 (480 - 24)
    put_u32(0x3B3D4, 0xE3510FD0, 0xE3510F72)  # y max cmp:   456 -> 832
    put_u32(0x3B3E0, 0xA3A07FD0, 0xA3A07F72)  # y max clamp: 456 -> 832
    put_u32(0x3B474, 0xE0030493, 0xE0030793)  # 100 * x / 480
    put_u32(0x3B484, 0xE0040793, 0xE0040493)  # 100 - 100 * y / 854

    # 4. Eco-Mode Toggle Knob (wid=692) runtime HI_GV_Widget_Move coordinates on Tree 33:
    #    Landscape was y=129, x_off=656, x_on=746 (off-screen >480 in portrait!).
    #    Portrait pill wid=690 is at (304, 138, 150, 60) -> knob y=144, x_off=310, x_on=400.
    put_u32(0x4FD34, 0xE3A02090, 0xE3A02081)  # r2 (y):     129 -> 144
    put_u32(0x4FD3C, 0xE3001136, 0xE3A01E29)  # r1 (x_off): 656 -> 310 (0x136)
    put_u32(0x4FD98, 0xE3001190, 0xE30012EA)  # r1 (x_on):  746 -> 400 (0x190)

    # 5 & 6. Runtime VO enRotate override trampoline + zero-drain offline sleep hook
    _install_vo_and_sleep_hooks(main_data)
    print("Patched main_app for 480x854 portrait LCD, touch, VO rotation & zero-drain offline sleep")


def patch_main_app_landscape(main_data: bytearray):
    """
    Patch main_app for standard horizontal 854x480 mounting:
      - Keeps stock 854x480 LCD RotateMode=1, touch axes, spot-metering, and Eco knob (656/746, 129)
      - Installs runtime /tmp/vo* VO rotation trampoline & /tmp/no_cloud + /tmp/force_sleep_now zero-drain sleep hook
    """
    _install_vo_and_sleep_hooks(main_data)
    print("Patched main_app for 854x480 landscape VO rotation & zero-drain offline sleep")


def _install_vo_and_sleep_hooks(main_data: bytearray):
    def put_u32(va: int, val: int, expected: int = None):
        foff = va - 0x10000
        cur, = struct.unpack_from("<I", main_data, foff)
        if expected is not None:
            assert cur == expected, f"Mismatch at VA {hex(va)}: got {hex(cur)}, expected {hex(expected)}"
        struct.pack_into("<I", main_data, foff, val)

    # 5. Runtime VO enRotate override trampoline at RX PT_LOAD[3] tail (VA 0x294FF0, file 0x284FF0)
    e_phoff, = struct.unpack_from("<I", main_data, 0x1C)
    e_phentsize, e_phnum = struct.unpack_from("<2H", main_data, 0x2A)
    extended_ph = False
    for i in range(e_phnum):
        ph_off = e_phoff + i * e_phentsize
        p_type, p_offset, p_vaddr, p_paddr, p_filesz, p_memsz, p_flags, p_align = struct.unpack_from("<8I", main_data, ph_off)
        if p_type == 1 and p_vaddr == 0x10000 and p_filesz == 0x284FF0:
            struct.pack_into("<2I", main_data, ph_off + 16, 0x285300, 0x285300)
            extended_ph = True
            break
    assert extended_ph, "Could not find PT_LOAD[3] to extend"

    def encode_bl(src_va: int, dst_va: int) -> int:
        off = ((dst_va - (src_va + 8)) >> 2) & 0xFFFFFF
        return 0xEB000000 | off

    def encode_b(src_va: int, dst_va: int) -> int:
        off = ((dst_va - (src_va + 8)) >> 2) & 0xFFFFFF
        return 0xEA000000 | off

    def encode_beq(src_va: int, dst_va: int) -> int:
        off = ((dst_va - (src_va + 8)) >> 2) & 0xFFFFFF
        return 0x0A000000 | off

    def encode_bne(src_va: int, dst_va: int) -> int:
        off = ((dst_va - (src_va + 8)) >> 2) & 0xFFFFFF
        return 0x1A000000 | off

    cave_va = 0x294FF0
    plt_access = 0x1E544
    trampoline_words = [
        0xE92D400B,                                      # +0x00: save {r0, r1, r3, lr}
        0xE28F004C,                                      # +0x04: r0 = "/tmp/vo270"
        0xE3A01000,                                      # +0x08: r1 = F_OK (0)
        encode_bl(cave_va + 0x0C, plt_access),           # +0x0C: access("/tmp/vo270", 0)
        0xE3500000,                                      # +0x10: cmp r0, #0
        0x03A02003,                                      # +0x14: if eq: r2 = 3 (ROTATE_270)
        0x08BD800B,                                      # +0x18: if eq: restore & return

        0xE28F0040,                                      # +0x1C: r0 = "/tmp/vo0"
        0xE3A01000,                                      # +0x20: r1 = 0
        encode_bl(cave_va + 0x24, plt_access),           # +0x24: access("/tmp/vo0", 0)
        0xE3500000,                                      # +0x28: cmp r0, #0
        0x03A02000,                                      # +0x2C: if eq: r2 = 0 (ROTATE_NONE)
        0x08BD800B,                                      # +0x30: if eq: restore & return

        0xE28F0034,                                      # +0x34: r0 = "/tmp/vo180"
        0xE3A01000,                                      # +0x38: r1 = 0
        encode_bl(cave_va + 0x3C, plt_access),           # +0x3C: access("/tmp/vo180", 0)
        0xE3500000,                                      # +0x40: cmp r0, #0
        0x03A02002,                                      # +0x44: if eq: r2 = 2 (ROTATE_180)
        0x08BD800B,                                      # +0x48: if eq: restore & return

        0xE5942B9C,                                      # +0x4C: default r2 = [r4 + 0xb9c] (1 = ROTATE_90)
        0xE8BD800B,                                      # +0x50: restore & return
        0xE1A00000,                                      # +0x54: pad
    ]
    assert len(trampoline_words) * 4 == 0x58

    cave_foff = cave_va - 0x10000
    assert all(b == 0 for b in main_data[cave_foff:0x285300]), "Code cave not empty"
    for idx, w in enumerate(trampoline_words):
        struct.pack_into("<I", main_data, cave_foff + idx * 4, w)

    str_blob = (
        b"/tmp/vo270\x00\x00" +
        b"/tmp/vo0\x00\x00\x00\x00" +
        b"/tmp/vo180\x00\x00" +
        b"/tmp/vo90\x00\x00\x00"
    )
    assert len(str_blob) == 48
    main_data[cave_foff + 0x58:cave_foff + 0x58 + len(str_blob)] = str_blob

    # Hook PDT_MEDIA_VoInit @ 0x5C500
    put_u32(0x5C500, encode_bl(0x5C500, cave_va), 0xE5942B9C)

    # 6. Offline zero-drain sleep & instant force-sleep hook in ipc018_sys_service_task_work (@ 0x2363C):
    #    - When /tmp/no_cloud exists (MI_CLOUD_ENABLE=0): sets busy.net=1 (+0x14), busy.rpc=0 (+0x0C),
    #      busy.tutk_key=0 (+0x24), and busy.msg=0 (+0x2C), eliminating the 60s net wait and 30-min (1800s) cloud/RPC/TUTK sleep blockers!
    #    - When /tmp/force_sleep_now exists ("В сон"): clears busy.rpc=0 (+0x0C), busy.bell=0 (+0x10),
    #      busy.wifi_wakeup=0 (+0x20), and busy.client=0 (+0x28) for 1-second MCU power-off while still letting active MP4 SD writes finish.
    cave2_va = 0x295088
    cave2_foff = cave2_va - 0x10000
    sleep_hook_words = [
        0xE92D5017,                                      # +0x00: save {r0, r1, r2, r4, r12, lr} (24B, 8B-aligned)
        0xE28F004C,                                      # +0x04: r0 = "/tmp/no_cloud" (+0x58)
        0xE3A01000,                                      # +0x08: r1 = F_OK (0)
        encode_bl(cave2_va + 0x0C, plt_access),          # +0x0C: access("/tmp/no_cloud", 0)
        0xE3500000,                                      # +0x10: cmp r0, #0
        0x1A000004,                                      # +0x14: if ne: skip to +0x2C
        0xE3A02001,                                      # +0x18: r2 = 1
        0xE5842014,                                      # +0x1C: [r4 + 0x14] = 1 (busy.net = 1)
        0xE584000C,                                      # +0x20: [r4 + 0x0C] = 0 (busy.rpc = 0)
        0xE5840024,                                      # +0x24: [r4 + 0x24] = 0 (busy.tutk_key = 0)
        0xE584002C,                                      # +0x28: [r4 + 0x2C] = 0 (busy.msg = 0)

        0xE28F0034,                                      # +0x2C: r0 = "/tmp/force_sleep_now" (+0x68)
        0xE3A01000,                                      # +0x30: r1 = F_OK (0)
        encode_bl(cave2_va + 0x34, plt_access),          # +0x34: access("/tmp/force_sleep_now", 0)
        0xE3500000,                                      # +0x38: cmp r0, #0
        0x1A000003,                                      # +0x3C: if ne: skip to +0x50
        0xE584000C,                                      # +0x40: [r4 + 0x0C] = 0 (busy.rpc = 0)
        0xE5840010,                                      # +0x44: [r4 + 0x10] = 0 (busy.bell = 0)
        0xE5840020,                                      # +0x48: [r4 + 0x20] = 0 (busy.wifi_wakeup = 0)
        0xE5840028,                                      # +0x4C: [r4 + 0x28] = 0 (busy.client = 0)

        0xE5943018,                                      # +0x50: displaced r3 = [r4 + 0x18] (busy.bind)
        0xE8BD9017,                                      # +0x54: restore {r0, r1, r2, r4, r12, pc}
    ]
    assert len(sleep_hook_words) * 4 == 0x58
    for idx, w in enumerate(sleep_hook_words):
        struct.pack_into("<I", main_data, cave2_foff + idx * 4, w)

    sleep_strs = (
        b"/tmp/no_cloud\x00\x00\x00" +
        b"/tmp/force_sleep_now\x00\x00\x00\x00"
    )
    assert len(sleep_strs) == 40
    main_data[cave2_foff + 0x58:cave2_foff + 0x58 + len(sleep_strs)] = sleep_strs

    put_u32(0x2363C, encode_bl(0x2363C, cave2_va), 0xE5943018)

    # 7. Resilient SD mount hook in STG_FSTOOL_Mount (@ 0x9D5F0 -> VA 0x295108):
    #    Detaches any residual early-boot /app/sd mount before calling mount(source, "/app/sd", "vfat", 0xc08, data),
    #    and treats EBUSY (errno == 16) as success (0) so pre-mounted FAT32 cards never trigger ErrorOutSdCard popup.
    cave3_va = 0x295108
    cave3_foff = cave3_va - 0x10000
    plt_umount = 0x1ED0C
    plt_mount = 0x1EBA4
    plt_errno = 0x1E0A0
    mount_hook_words = [
        0xE92D401F,                                      # +0x00: save {r0..r4, lr} (24B, 8B-aligned)
        0xE1A00001,                                      # +0x04: r0 = r1 ("/app/sd")
        encode_bl(cave3_va + 0x08, plt_umount),          # +0x08: umount("/app/sd")
        0xE59D4018,                                      # +0x0C: r4 = [sp + 24] (5th arg: data)
        0xE24DD008,                                      # +0x10: sp -= 8 (8B-aligned stack slot)
        0xE58D4000,                                      # +0x14: [sp] = data
        0xE28DC008,                                      # +0x18: r12 = sp + 8
        0xE89C000F,                                      # +0x1C: reload {r0..r3}
        encode_bl(cave3_va + 0x20, plt_mount),           # +0x20: mount(source, target, fstype, 0xc08, data)
        0xE3500000,                                      # +0x24: cmp r0, #0
        0x0A000004,                                      # +0x28: if eq -> +0x40 (return 0)
        encode_bl(cave3_va + 0x2C, plt_errno),           # +0x2C: __errno_location()
        0xE5901000,                                      # +0x30: r1 = errno
        0xE3510010,                                      # +0x34: cmp r1, #16 (EBUSY)
        0x03A00000,                                      # +0x38: if EBUSY -> r0 = 0
        0x13E00000,                                      # +0x3C: else -> r0 = -1
        0xE28DD018,                                      # +0x40: sp += 24
        0xE8BD8010,                                      # +0x44: restore {r4, pc}
    ]
    assert len(mount_hook_words) * 4 == 0x48
    assert all(b == 0 for b in main_data[cave3_foff:cave3_foff + 0x48]), "Cave3 not empty"
    for idx, w in enumerate(mount_hook_words):
        struct.pack_into("<I", main_data, cave3_foff + idx * 4, w)

    put_u32(0x9D5F0, encode_bl(0x9D5F0, cave3_va), 0xEBFE056B)

    # 8. Fix shadow_device_socket_init 83% CPU POLLHUP spin & FD leak (@ 0x1B32AC / 0x1B337C -> VA 0x295150)
    cave4_va = 0x295150
    cave4_foff = cave4_va - 0x10000
    plt_socket = 0x1EA30
    plt_close = 0x1E760
    no_cloud_str_va = cave2_va + 0x58
    sub_no_cloud = (cave4_va + 0x0C) - no_cloud_str_va
    assert 0 <= sub_no_cloud < 0x100
    rpc_sock_hook_words = [
        0xE92D4008,                                      # +0x00: save {r3, lr} (8B-aligned)
        0xE24F0000 | sub_no_cloud,                       # +0x04: r0 = "/tmp/no_cloud" (0x2950E0)
        0xE3A01000,                                      # +0x08: r1 = F_OK (0)
        encode_bl(cave4_va + 0x0C, plt_access),          # +0x0C: access("/tmp/no_cloud", 0)
        0xE3500000,                                      # +0x10: cmp r0, #0
        0x03E00000,                                      # +0x14: if eq: r0 = -1 (skip 10s otd connect & avoid unconnected fd)
        0x08BD8008,                                      # +0x18: if eq: restore {r3, pc}
        0xE3A00002,                                      # +0x1C: r0 = AF_INET (2)
        0xE3A01001,                                      # +0x20: r1 = SOCK_STREAM (1)
        0xE3A02000,                                      # +0x24: r2 = 0
        0xE8BD4008,                                      # +0x28: restore {r3, lr}
        encode_b(cave4_va + 0x2C, plt_socket),           # +0x2C: tail-call socket(2, 1, 0)

        0xE1A00004,                                      # +0x30: fail_cleanup: r0 = r4 (unconnected sock)
        encode_bl(cave4_va + 0x34, plt_close),           # +0x34: close(r4)
        0xE3E04000,                                      # +0x38: r4 = -1 (pollfd.fd = -1 -> 0% CPU)
        encode_b(cave4_va + 0x3C, 0x1B32C8),             # +0x3C: jump back to epilogue
    ]
    assert len(rpc_sock_hook_words) * 4 == 0x40
    for idx, w in enumerate(rpc_sock_hook_words):
        struct.pack_into("<I", main_data, cave4_foff + idx * 4, w)

    put_u32(0x1B32AC, encode_bl(0x1B32AC, cave4_va), 0xEBF9ADDF)
    put_u32(0x1B337C, encode_b(0x1B337C, cave4_va + 0x30), 0xEAFFFFD1)

    # 9. Autonomous Hardware WoWLAN Sleep Hook (@ 0x023DC0 -> VA 0x295190)
    cave5_va = 0x295190
    cave5_foff = cave5_va - 0x10000
    plt_system = 0x1E124
    sub_no_cloud5 = (cave5_va + 0x08) - no_cloud_str_va
    assert 0 <= sub_no_cloud5 < 0x100
    pre_sleep_str_va = cave5_va + 0x40
    wowlan_rdy_str_va = cave5_va + 0x5C
    add_pre_sleep = pre_sleep_str_va - ((cave5_va + 0x1C) + 8)
    add_wowlan_rdy = wowlan_rdy_str_va - ((cave5_va + 0x24) + 8)
    assert 0 <= add_pre_sleep < 0x100 and 0 <= add_wowlan_rdy < 0x100
    wowlan_sleep_words = [
        0xE24F0000 | sub_no_cloud5,                # +0x00: r0 = "/tmp/no_cloud" (0x2950E0)
        0xE3A01000,                                # +0x04: r1 = F_OK (0)
        encode_bl(cave5_va + 0x08, plt_access),    # +0x08: access("/tmp/no_cloud", 0)
        0xE3500000,                                # +0x0C: cmp r0, #0
        encode_bne(cave5_va + 0x10, 0x023DD0),     # +0x10: if MI_CLOUD_ENABLE=1 -> stock 0x023DD0 (r4 intact)
        0xE3A00000,                                # +0x14: r0 = 0
        encode_bl(cave5_va + 0x18, 0x062310),      # +0x18: ipc018_mcu_set_ps_mode(0)
        0xE28F0000 | add_pre_sleep,                # +0x1C: r0 = "/app/eye/eye_pre_sleep.sh"
        encode_bl(cave5_va + 0x20, plt_system),    # +0x20: system("/app/eye/eye_pre_sleep.sh")
        0xE28F0000 | add_wowlan_rdy,               # +0x24: r0 = "/tmp/wowlan_ready"
        0xE3A01000,                                # +0x28: r1 = F_OK (0)
        encode_bl(cave5_va + 0x2C, plt_access),    # +0x2C: access("/tmp/wowlan_ready", 0)
        0xE3500000,                                # +0x30: cmp r0, #0
        encode_bne(cave5_va + 0x34, 0x023E84),     # +0x34: if Wi-Fi down -> deep power-off 0x62310(0)+0x622D0()
        encode_bl(cave5_va + 0x38, 0x062298),      # +0x38: ipc018_mcu_action_sleep() (0x21b00011 <1mA WoWLAN)
        encode_b(cave5_va + 0x3C, 0x023E64),       # +0x3C: usleep(1s) -> system("reboot") -> epilogue
    ]
    assert len(wowlan_sleep_words) * 4 == 0x40
    for idx, w in enumerate(wowlan_sleep_words):
        struct.pack_into("<I", main_data, cave5_foff + idx * 4, w)

    wowlan_strs = (
        b"/app/eye/eye_pre_sleep.sh\x00\x00\x00" +
        b"/tmp/wowlan_ready\x00\x00\x00"
    )
    assert len(wowlan_strs) == 48
    main_data[cave5_foff + 0x40:cave5_foff + 0x40 + len(wowlan_strs)] = wowlan_strs

    put_u32(0x023DC0, encode_beq(0x023DC0, cave5_va), 0x0A000002)

    # 10. Home Dock Snap (447) & Record (454) Button Dispatcher (@ 0x03CDCC -> VA 0x295200..<=0x295300)
    cave6_va = 0x295200
    cave6_foff = cave6_va - 0x10000
    snap_cmd_va = cave6_va + 0x84
    rec_cmd_va = cave6_va + 0xB4
    add_snap_cmd = snap_cmd_va - ((cave6_va + 0x34) + 8)
    add_rec_cmd = rec_cmd_va - ((cave6_va + 0x44) + 8)
    assert 0 <= add_snap_cmd < 0x100 and 0 <= add_rec_cmd < 0x100
    dock_hook_words = [
        0xE30021BF,                                      # +0x00: movw r2, #447
        0xE1500002,                                      # +0x04: cmp r0, r2
        encode_beq(cave6_va + 0x08, cave6_va + 0x2C),    # +0x08: beq snap_entry
        0xE30021C6,                                      # +0x0C: movw r2, #454
        0xE1500002,                                      # +0x10: cmp r0, r2
        encode_beq(cave6_va + 0x14, cave6_va + 0x3C),    # +0x14: beq rec_entry
        0xE92D4010,                                      # +0x18: push {r4, lr} (displaced 0x03CDCC)
        0xE30001CF,                                      # +0x1C: movw r0, #463
        0xE3A010C8,                                      # +0x20: mov r1, #200
        encode_bl(cave6_va + 0x24, 0x0F3200),            # +0x24: HI_GV_Widget_SetTextByID(463, 200)
        encode_b(cave6_va + 0x28, 0x03CDD0),             # +0x28: b 0x03CDD0

        0xE92D4070,                                      # +0x2C: snap_entry: push {r4, r5, r6, lr}
        0xE3A04007,                                      # +0x30: mov r4, #7 ("Photo saved" / "Снимок сохранён")
        0xE28F5000 | add_snap_cmd,                       # +0x34: adr r5, snap_cmd
        encode_b(cave6_va + 0x38, cave6_va + 0x48),      # +0x38: b common_action

        0xE92D4070,                                      # +0x3C: rec_entry: push {r4, r5, r6, lr}
        0xE3A04008,                                      # +0x40: mov r4, #8 ("Recording 10s..." / "Запись 10 сек...")
        0xE28F5000 | add_rec_cmd,                        # +0x44: adr r5, rec_cmd

        0xE3A00000,                                      # +0x48: common_action: mov r0, #0
        encode_bl(cave6_va + 0x4C, 0x022908),            # +0x4C: ipc018_reset_sleep_timer(0)
        0xE30001CE,                                      # +0x50: movw r0, #462
        0xE3A01001,                                      # +0x54: mov r1, #1
        encode_bl(cave6_va + 0x58, 0x03F848),            # +0x58: PDT_UI_HOME_TOAST_Show(462, 1)
        0xE30001CF,                                      # +0x5C: movw r0, #463
        0xE1A01004,                                      # +0x60: mov r1, r4
        encode_bl(cave6_va + 0x64, 0x0F3200),            # +0x64: HI_GV_Widget_SetTextByID(463, str_id)
        0xE30001CF,                                      # +0x68: movw r0, #463
        0xE3A01000,                                      # +0x6C: mov r1, #0
        encode_bl(cave6_va + 0x70, 0x0F2C2C),            # +0x70: HI_GV_Widget_Paint(463, 0)
        0xE1A00005,                                      # +0x74: mov r0, r5
        encode_bl(cave6_va + 0x78, plt_system),          # +0x78: system(cmd)
        0xE3A00000,                                      # +0x7C: mov r0, #0
        0xE8BD8070,                                      # +0x80: pop {r4, r5, r6, pc}
    ]
    assert len(dock_hook_words) * 4 == 0x84
    dock_strs = (
        b"/app/eye/ui_action.sh snap >/dev/null 2>&1 &\x00\x00\x00\x00" +
        b"/app/eye/ui_action.sh record 10 >/dev/null 2>&1 &\x00\x00\x00"
    )
    assert cave6_va + 0x84 + len(dock_strs) <= 0x295300, "cave6 exceeds PT_LOAD[3] limit"
    for idx, w in enumerate(dock_hook_words):
        struct.pack_into("<I", main_data, cave6_foff + idx * 4, w)
    main_data[cave6_foff + 0x84:cave6_foff + 0x84 + len(dock_strs)] = dock_strs
    put_u32(0x03CDCC, encode_b(0x03CDCC, cave6_va), 0xE92D4010)


if __name__ == "__main__":
    build_portrait_higv()
