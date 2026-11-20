import math
import os
import sys
from PIL import Image, ImageDraw, ImageFont

sys.stdout.reconfigure(encoding="utf-8")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_PIC_DIR = os.path.join(BASE_DIR, "out_patch_435", "res_pic")
OUT_SPLASH_DIR = os.path.join(BASE_DIR, "out_patch_435", "mtd5_splashes")
SS = 4  # 4x supersampling for crisp anti-aliased corners and vectors


def new_ss(w: int, h: int):
    im = Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))
    return im, ImageDraw.Draw(im)


def down(im: Image.Image, w: int, h: int) -> Image.Image:
    return im.resize((w, h), Image.Resampling.LANCZOS)


def save_png(im: Image.Image, name: str, out_dir: str = OUT_PIC_DIR):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    im.save(path, "PNG", optimize=True)
    return os.path.getsize(path)


def make_card(w: int, h: int, radius: int, fill_rgba, border_rgba=None, top_hl_rgba=None, divider_x=None, divider_xs=None) -> Image.Image:
    im, d = new_ss(w, h)
    r = radius * SS
    pad = SS // 2
    box = [pad, pad, w * SS - 1 - pad, h * SS - 1 - pad]
    if border_rgba:
        d.rounded_rectangle(box, radius=r, fill=fill_rgba, outline=border_rgba, width=SS)
    else:
        d.rounded_rectangle(box, radius=r, fill=fill_rgba)
    if top_hl_rgba:
        ix0 = (radius + 2) * SS
        ix1 = (w - radius - 2) * SS
        if ix1 > ix0:
            d.line([(ix0, SS + 1), (ix1, SS + 1)], fill=top_hl_rgba, width=max(1, SS // 2))
    dividers = []
    if divider_x is not None:
        dividers.append(divider_x)
    if divider_xs:
        dividers.extend(divider_xs)
    if dividers:
        dy0 = int(h * 0.24 * SS)
        dy1 = int(h * 0.76 * SS)
        for div_x in dividers:
            dx = div_x * SS
            d.line([(dx, dy0), (dx, dy1)], fill=(148, 163, 184, 64), width=SS)
    return down(im, w, h)


def make_3slice_pill(cap_w: int, h: int, fill_rgba):
    full_w = cap_w * 2 + 8
    im, d = new_ss(full_w, h)
    r = (h * SS) // 2
    d.rounded_rectangle([0, 0, full_w * SS - 1, h * SS - 1], radius=r, fill=fill_rgba)
    full = down(im, full_w, h)
    left = full.crop((0, 0, cap_w, h))
    center = full.crop((cap_w + 3, 0, cap_w + 4, h))
    right = full.crop((full_w - cap_w, 0, full_w, h))
    return left, center, right


def make_modal_9patch(r: int, fill_rgba):
    full_sz = r * 2 + 8
    im, d = new_ss(full_sz, full_sz)
    d.rounded_rectangle([0, 0, full_sz * SS - 1, full_sz * SS - 1], radius=r * SS, fill=fill_rgba)
    full = down(im, full_sz, full_sz)
    tl = full.crop((0, 0, r, r))
    tr = full.crop((full_sz - r, 0, full_sz, r))
    bl = full.crop((0, full_sz - r, r, full_sz))
    br = full.crop((full_sz - r, full_sz - r, full_sz, full_sz))
    pt = Image.new("RGBA", (1, 1), fill_rgba)
    tb = Image.new("RGBA", (1, r), fill_rgba)
    rl = Image.new("RGBA", (r, 1), fill_rgba)
    return pt, tl, tr, bl, br, tb, rl


def make_circle_pm_icon(sz: int, is_plus: bool) -> Image.Image:
    im, d = new_ss(sz, sz)
    pad = SS
    d.ellipse(
        [pad, pad, sz * SS - 1 - pad, sz * SS - 1 - pad],
        fill=(38, 53, 77, 255),
        outline=(62, 84, 118, 255),
        width=SS,
    )
    cx = (sz * SS) // 2
    cy = (sz * SS) // 2
    arm = int(sz * 0.23 * SS)
    stroke = int(2.2 * SS)
    fg = (241, 245, 249, 255)
    d.line([(cx - arm, cy), (cx + arm, cy)], fill=fg, width=stroke)
    if is_plus:
        d.line([(cx, cy - arm), (cx, cy + arm)], fill=fg, width=stroke)
    return down(im, sz, sz)


def make_chevron_icon(w: int, h: int, direction: str, fg_rgba, pill_bg=None, pill_border=None) -> Image.Image:
    im, d = new_ss(w, h)
    if pill_bg:
        pad = SS // 2
        d.rounded_rectangle(
            [pad, pad, w * SS - 1 - pad, h * SS - 1 - pad],
            radius=12 * SS,
            fill=pill_bg,
            outline=pill_border,
            width=SS if pill_border else 0,
        )
    cx = (w * SS) // 2
    cy = (h * SS) // 2
    arm_y = int(min(w, h) * 0.24 * SS)
    arm_x = int(min(w, h) * 0.16 * SS)
    stroke = int(2.4 * SS)
    if direction == "left":
        pts = [(cx + arm_x, cy - arm_y), (cx - arm_x, cy), (cx + arm_x, cy + arm_y)]
    else:
        pts = [(cx - arm_x, cy - arm_y), (cx + arm_x, cy), (cx - arm_x, cy + arm_y)]
    d.line([pts[0], pts[1]], fill=fg_rgba, width=stroke)
    d.line([pts[1], pts[2]], fill=fg_rgba, width=stroke)
    r = stroke // 2
    for px, py in pts:
        d.ellipse([px - r, py - r, px + r, py + r], fill=fg_rgba)
    return down(im, w, h)


def make_switch_knob(sz: int) -> Image.Image:
    im, d = new_ss(sz, sz)
    # Subtle drop shadow
    d.ellipse([3 * SS, 4 * SS, (sz - 3) * SS, (sz - 2) * SS], fill=(8, 13, 23, 90))
    d.ellipse([2 * SS, 2 * SS, (sz - 2) * SS, (sz - 2) * SS], fill=(248, 250, 252, 255))
    return down(im, sz, sz)


def make_statusbar_scrim(h: int) -> Image.Image:
    im = Image.new("RGBA", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        alpha = int(round(205 * (1.0 - 0.52 * t)))
        im.putpixel((0, y), (10, 15, 26, alpha))
    return im


def build_modern_skin_assets(out_pic_dir: str = OUT_PIC_DIR, orientation: str = "portrait"):
    assert orientation in ("portrait", "landscape"), f"Invalid orientation: {orientation}"
    total_bytes = 0
    count = 0

    def emit(im, fn):
        nonlocal total_bytes, count
        total_bytes += save_png(im, fn, out_pic_dir)
        count += 1

    # 1. Native 1:1 Settings Cards (#162032 surface + #293A54 hairline border)
    card_fill = (22, 32, 50, 248)
    card_border = (43, 59, 86, 255)
    card_hl = (148, 163, 184, 34)
    if orientation == "portrait":
        emit(make_card(456, 76, 16, card_fill, card_border, card_hl), "bg_set.png")
        emit(make_card(456, 104, 16, card_fill, card_border, card_hl), "bg_large_set.png")
        emit(make_card(456, 132, 16, card_fill, card_border, card_hl), "bg_big_set.png")
        dock_w, dock_h, dock_r = 456, 76, 22
        opt_w, modal_btn_w = 416, 204
    else:
        emit(make_card(814, 60, 14, card_fill, card_border, card_hl), "bg_set.png")
        emit(make_card(814, 80, 14, card_fill, card_border, card_hl), "bg_large_set.png")
        emit(make_card(814, 90, 16, card_fill, card_border, card_hl), "bg_big_set.png")
        dock_w, dock_h, dock_r = 456, 64, 20
        opt_w, modal_btn_w = 580, 280

    # 2. Home Live View Floating Glass Dock (4 equal columns)
    emit(
        make_card(
            dock_w, dock_h, dock_r,
            fill_rgba=(13, 19, 31, 218),
            border_rgba=(148, 163, 184, 78),
            top_hl_rgba=(255, 255, 255, 36),
            divider_xs=(dock_w // 4, dock_w // 2, (dock_w * 3) // 4),
        ),
        "home_page_main_buttons_bg.png",
    )
    emit(make_statusbar_scrim(34), "statusbar_bg.png")

    # 3. Elevated Slate Modal 9-Patch (#1B273B, seamless across Skins 24..28)
    pt, tl, tr, bl, br, tb, rl = make_modal_9patch(20, (27, 39, 59, 255))
    emit(pt, "point_c2a3041.png")
    emit(tl, "rect_r20_c2a3041_tl.png")
    emit(tr, "rect_r20_c2a3041_tr.png")
    emit(bl, "rect_r20_c2a3041_bl.png")
    emit(br, "rect_r20_c2a3041_br.png")
    emit(tb, "rect_r20_c2a3041_t_b_line.png")
    emit(rl, "rect_r20_c2a3041_r_l_line.png")

    # 4. Native 1:1 Modal & Alert Buttons (Zero oval stretching!)
    sec_fill, sec_border = (38, 53, 77, 255), (60, 82, 115, 255)
    pri_fill, pri_border = (37, 99, 235, 255), (96, 165, 250, 255)
    emit(make_card(opt_w, 60, 14, pri_fill, pri_border), "bg_tanchuang.png")
    emit(make_card(modal_btn_w, 60, 14, sec_fill, sec_border), "button_1.png")
    emit(make_card(modal_btn_w, 60, 14, pri_fill, pri_border), "button_2.png")
    emit(make_card(180, 56, 14, sec_fill, sec_border), "button_4.png")
    emit(make_card(180, 56, 14, pri_fill, pri_border), "button_5.png")

    # 5. Progress Bars & Eco-Mode Switch Capsules
    tl_bg, tc_bg, tr_bg = make_3slice_pill(3, 6, (148, 163, 184, 72))
    emit(tl_bg, "o50_cffffff_l.png")
    emit(tc_bg, "o50_cffffff_t_line.png")
    emit(tr_bg, "o50_cffffff_r.png")

    tl_fg, tc_fg, tr_fg = make_3slice_pill(3, 6, (59, 130, 246, 255))
    emit(tl_fg, "o100_c496ee0_l.png")
    emit(tc_fg, "o100_c496ee0_t_line.png")
    emit(tr_fg, "o100_c496ee0_r.png")

    sw_off_l, sw_off_c, sw_off_r = make_3slice_pill(30, 60, (38, 53, 77, 255))
    emit(sw_off_l, "o30_cffffff_l.png")
    emit(sw_off_c, "o30_cffffff_c.png")
    emit(sw_off_r, "o30_cffffff_r.png")

    sw_on_l, sw_on_c, sw_on_r = make_3slice_pill(30, 60, (37, 99, 235, 255))
    emit(sw_on_l, "o100_c496ee0_h60_l.png")
    emit(sw_on_c, "o100_c496ee0_h60_c.png")
    emit(sw_on_r, "o100_c496ee0_h60_r.png")
    emit(make_switch_knob(48), "icon_power_mode_switch.png")

    # 6. Toast Pill 3-Slice (Dark Slate #1E293B)
    tst_l, tst_c, tst_r = make_3slice_pill(14, 60, (30, 41, 59, 244))
    emit(tst_l, "toast_bg_left.png")
    emit(tst_c, "toast_bg_center.png")
    emit(tst_r, "toast_bg_right.png")

    # 7. Crisp Anti-Aliased Navigation & +/- Icons
    emit(make_circle_pm_icon(30, False), "icon_voice_reduce.png")
    emit(make_circle_pm_icon(30, True), "icon_voice_add.png")
    emit(make_chevron_icon(30, 30, "right", (148, 163, 184, 255)), "icon_turn.png")
    emit(make_chevron_icon(30, 30, "left", (241, 245, 249, 255)), "icon_back.png")
    emit(make_chevron_icon(36, 36, "left", (241, 245, 249, 255), (15, 23, 38, 180), (148, 163, 184, 70)), "icon_back_new.png")

    nav_act_bg, nav_act_bd = (28, 41, 62, 255), (51, 71, 102, 255)
    nav_dis_bg, nav_dis_bd = (22, 32, 50, 110), (36, 50, 74, 110)
    emit(make_chevron_icon(60, 40, "left", (241, 245, 249, 255), nav_act_bg, nav_act_bd), "icon_shangye.png")
    emit(make_chevron_icon(60, 40, "left", (71, 85, 105, 190), nav_dis_bg, nav_dis_bd), "icon_shangye_d.png")
    emit(make_chevron_icon(60, 40, "right", (241, 245, 249, 255), nav_act_bg, nav_act_bd), "icon_xiaye.png")
    emit(make_chevron_icon(60, 40, "right", (71, 85, 105, 190), nav_dis_bg, nav_dis_bd), "icon_xiaye_d.png")

    print(f"Generated {count} modern 1:1 {orientation} PNG assets in {out_pic_dir} ({total_bytes} bytes total)")


def _rgb_to_ycrcb_bt601(r: int, g: int, b: int):
    y = int(round(16.0 + (65.481 * r + 128.553 * g + 24.966 * b) / 255.0))
    cr = int(round(128.0 + (112.0 * r - 93.786 * g - 18.214 * b) / 255.0))
    cb = int(round(128.0 + (-37.797 * r - 74.203 * g + 112.0 * b) / 255.0))
    return (
        max(16, min(235, y)),
        max(16, min(240, cr)),
        max(16, min(240, cb)),
    )


def encode_landscape_to_mtd5_nv21(im_land: Image.Image) -> bytes:
    """
    Encode an 800x450 horizontal RGB image into an 800x450 BT.601 studio-swing NV21
    (Y + interleaved [Cr, Cb]) buffer matching Huawei LiteOS VO boot splash buffers in mtd5 (540,000 bytes).
    """
    assert im_land.size == (800, 450) and im_land.mode == "RGB"
    assert _rgb_to_ycrcb_bt601(73, 110, 224) == (112, 104, 184)

    y_cache = {}
    y_plane = bytearray(800 * 450)
    for idx, rgb in enumerate(im_land.getdata()):
        yv = y_cache.get(rgb)
        if yv is None:
            yv = _rgb_to_ycrcb_bt601(*rgb)[0]
            y_cache[rgb] = yv
        y_plane[idx] = yv

    im_sub = im_land.resize((400, 225), Image.Resampling.BOX)
    uv_cache = {}
    vu_plane = bytearray(400 * 225 * 2)
    out_i = 0
    for rgb in im_sub.getdata():
        crcb = uv_cache.get(rgb)
        if crcb is None:
            _, cr, cb = _rgb_to_ycrcb_bt601(*rgb)
            crcb = (cr, cb)
            uv_cache[rgb] = crcb
        vu_plane[out_i] = crcb[0]      # V (Cr)
        vu_plane[out_i + 1] = crcb[1]  # U (Cb)
        out_i += 2

    nv21 = bytes(y_plane) + bytes(vu_plane)
    assert len(nv21) == 540000
    return nv21


def encode_portrait_to_mtd5_nv21(im_port: Image.Image) -> bytes:
    """
    Convert a 450x800 portrait RGB image (upright on a 90°-CW-mounted door)
    into an 800x450 BT.601 studio-swing NV21 buffer (540,000 bytes).
    """
    assert im_port.size == (450, 800) and im_port.mode == "RGB"
    im_land = im_port.transpose(Image.Transpose.ROTATE_90)
    assert im_land.size == (800, 450)
    assert im_land.transpose(Image.Transpose.ROTATE_270).tobytes() == im_port.tobytes()
    return encode_landscape_to_mtd5_nv21(im_land)


def decode_mtd5_nv21_to_portrait_rgb(nv21: bytes) -> Image.Image:
    """Decode 800x450 BT.601 studio-swing NV21 from mtd5 and rotate 90° CW to 450x800 portrait."""
    assert len(nv21) == 540000
    y_bytes = nv21[:360000]
    vu_bytes = nv21[360000:]
    rgb_land = bytearray(800 * 450 * 3)
    cache = {}
    p = 0
    for ly in range(450):
        uv_row = (ly >> 1) * 800
        y_row = ly * 800
        for lx in range(800):
            yv = y_bytes[y_row + lx]
            uv_idx = uv_row + (lx & ~1)
            cr = vu_bytes[uv_idx]
            cb = vu_bytes[uv_idx + 1]
            key = (yv, cr, cb)
            rgb = cache.get(key)
            if rgb is None:
                c = yv - 16.0
                d = cb - 128.0
                e = cr - 128.0
                r = max(0, min(255, int(round(1.164383 * c + 1.596027 * e))))
                g = max(0, min(255, int(round(1.164383 * c - 0.391762 * d - 0.812968 * e))))
                b = max(0, min(255, int(round(1.164383 * c + 2.017232 * d))))
                rgb = (r, g, b)
                cache[key] = rgb
            rgb_land[p] = rgb[0]
            rgb_land[p + 1] = rgb[1]
            rgb_land[p + 2] = rgb[2]
            p += 3
    im_land = Image.frombytes("RGB", (800, 450), bytes(rgb_land))
    # Simulate 90° CW door mounting (PIL ROTATE_270 = 90° CW)
    return im_land.transpose(Image.Transpose.ROTATE_270)


def _load_splash_font(bold: bool, px: int) -> ImageFont.FreeTypeFont:
    candidates = (
        [r"C:\Windows\Fonts\seguisb.ttf", r"C:\Windows\Fonts\segoeuib.ttf", r"C:\Windows\Fonts\arialbd.ttf"]
        if bold
        else [r"C:\Windows\Fonts\segoeui.ttf", r"C:\Windows\Fonts\arial.ttf"]
    )
    for fp in candidates:
        if os.path.isfile(fp):
            return ImageFont.truetype(fp, px)
    raise FileNotFoundError("Could not find Windows Cyrillic TTF font")


def _draw_centered_text(d: ImageDraw.ImageDraw, cx: int, y: int, text: str, font: ImageFont.FreeTypeFont, fill):
    bbox = d.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    d.text((cx - tw // 2 - bbox[0], y - bbox[1]), text, font=font, fill=fill)


def _render_splash_card(kind: str, orientation: str = "portrait") -> Image.Image:
    """
    Render a clean Modern Slate Dark (#0D131F) splash screen:
      - portrait:  450x800 (central 450x420 supersampled)
      - landscape: 800x450 (central 560x360 supersampled)
    Outer regions stay pure flat #0D131F so HiSilicon hardware ugzip (wbits=-13) compresses tightly.
    """
    bg_rgb = (13, 19, 31)  # #0D131F (matches main_app Modern Slate Dark UI)
    if orientation == "portrait":
        base = Image.new("RGB", (450, 800), bg_rgb)
        box_w, box_h = 450, 420
        box_x0, box_y0 = 0, 190
    else:
        base = Image.new("RGB", (800, 450), bg_rgb)
        box_w, box_h = 560, 360
        box_x0, box_y0 = 120, 45

    ov = Image.new("RGBA", (box_w * SS, box_h * SS), (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)

    cx = (box_w * SS) // 2
    y_shift = 0 if orientation == "portrait" else -18
    f_title = _load_splash_font(True, 27 * SS)
    f_sub = _load_splash_font(False, 16 * SS)
    f_pill = _load_splash_font(False, 14 * SS)

    if kind == "boot":
        # Precision Smart-Peephole Camera Lens Emblem
        cy = (104 + y_shift) * SS
        r_outer = 56 * SS
        d.ellipse(
            [cx - r_outer, cy - r_outer, cx + r_outer, cy + r_outer],
            fill=(22, 32, 50, 255),
            outline=(45, 64, 94, 255),
            width=2 * SS,
        )
        r_mid = 39 * SS
        d.ellipse(
            [cx - r_mid, cy - r_mid, cx + r_mid, cy + r_mid],
            fill=(11, 17, 29, 255),
            outline=(37, 99, 235, 255),
            width=int(3.5 * SS),
        )
        r_core = 21 * SS
        d.ellipse(
            [cx - r_core, cy - r_core, cx + r_core, cy + r_core],
            fill=(17, 29, 52, 255),
            outline=(56, 189, 248, 185),
            width=int(1.6 * SS),
        )
        r_pupil = 9 * SS
        d.ellipse(
            [cx - r_pupil, cy - r_pupil, cx + r_pupil, cy + r_pupil],
            fill=(9, 13, 22, 255),
        )
        # Optical lens specular highlight dot
        hx, hy, hr = cx + 8 * SS, cy - 9 * SS, int(3.8 * SS)
        d.ellipse([hx - hr, hy - hr, hx + hr, hy + hr], fill=(186, 230, 253, 235))

        _draw_centered_text(d, cx, (190 + y_shift) * SS, "Умный видеоглазок", f_title, (241, 245, 249, 255))
        _draw_centered_text(d, cx, (232 + y_shift) * SS, "Xiaomi Cat Eye M1", f_sub, (148, 163, 184, 255))

        # Subtle status capsule at bottom of card (optically centered dot + label)
        pill_label = "Загрузка системы..."
        bbox = d.textbbox((0, 0), pill_label, font=f_pill)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        dot_r = int(4.2 * SS)
        gap = 10 * SS
        group_w = dot_r * 2 + gap + tw
        pw, ph = group_w + 40 * SS, 36 * SS
        px0, py0 = cx - pw // 2, (284 + y_shift) * SS
        d.rounded_rectangle(
            [px0, py0, px0 + pw, py0 + ph],
            radius=18 * SS,
            fill=(22, 32, 50, 255),
            outline=(41, 58, 84, 255),
            width=int(1.2 * SS),
        )
        gx0 = cx - group_w // 2
        dot_x = gx0 + dot_r
        dot_y = py0 + ph // 2
        d.ellipse([dot_x - dot_r, dot_y - dot_r, dot_x + dot_r, dot_y + dot_r], fill=(59, 130, 246, 255))
        d.text(
            (gx0 + dot_r * 2 + gap - bbox[0], py0 + (ph - th) // 2 - bbox[1]),
            pill_label,
            font=f_pill,
            fill=(203, 213, 225, 255),
        )

    elif kind == "upgrade":
        # Modern Blue Sync Badge (replaces 升级中...)
        cy = (114 + y_shift) * SS
        r_bg = 46 * SS
        d.ellipse(
            [cx - r_bg, cy - r_bg, cx + r_bg, cy + r_bg],
            fill=(37, 99, 235, 255),
            outline=(96, 165, 250, 220),
            width=int(1.8 * SS),
        )
        r_arc = 20 * SS
        arc_box = [cx - r_arc, cy - r_arc, cx + r_arc, cy + r_arc]
        stroke = int(3.8 * SS)
        fg = (248, 250, 252, 255)
        d.arc(arc_box, start=205, end=340, fill=fg, width=stroke)
        d.arc(arc_box, start=25, end=160, fill=fg, width=stroke)
        # Arrowheads at 340 deg and 160 deg
        for ang_deg, dir_sign in ((340.0, 1.0), (160.0, -1.0)):
            rad = math.radians(ang_deg)
            ax = cx + r_arc * math.cos(rad)
            ay = cy + r_arc * math.sin(rad)
            ah = 7.5 * SS
            if dir_sign > 0:
                pts = [(ax + 2 * SS, ay + 2 * SS), (ax - ah, ay + 1 * SS), (ax - 1 * SS, ay - ah)]
            else:
                pts = [(ax - 2 * SS, ay - 2 * SS), (ax + ah, ay - 1 * SS), (ax + 1 * SS, ay + ah)]
            d.polygon(pts, fill=fg)

        _draw_centered_text(d, cx, (192 + y_shift) * SS, "Обновление системы...", f_title, (241, 245, 249, 255))
        _draw_centered_text(d, cx, (234 + y_shift) * SS, "Не выключайте питание", f_sub, (148, 163, 184, 255))

    elif kind == "nocam":
        # Camera Ribbon Disconnected Warning (replaces 无法连接猫眼)
        cy = (114 + y_shift) * SS
        r_bg = 46 * SS
        d.ellipse(
            [cx - r_bg, cy - r_bg, cx + r_bg, cy + r_bg],
            fill=(27, 39, 59, 255),
            outline=(245, 158, 11, 235),
            width=int(2.2 * SS),
        )
        amber = (251, 191, 36, 255)
        # Minimalist camera body + lens + diagonal disconnect slash
        bw, bh = 38 * SS, 26 * SS
        d.rounded_rectangle(
            [cx - bw // 2, cy - bh // 2 + 2 * SS, cx + bw // 2, cy + bh // 2 + 2 * SS],
            radius=5 * SS,
            outline=amber,
            width=int(2.8 * SS),
        )
        lr = 7 * SS
        d.ellipse([cx - lr, cy - lr + 2 * SS, cx + lr, cy + lr + 2 * SS], outline=amber, width=int(2.6 * SS))
        sl = 24 * SS
        d.line([(cx - sl, cy + sl), (cx + sl, cy - sl)], fill=(248, 113, 113, 255), width=int(3.2 * SS))

        _draw_centered_text(d, cx, (192 + y_shift) * SS, "Нет связи с камерой", f_title, (241, 245, 249, 255))
        _draw_centered_text(d, cx, (234 + y_shift) * SS, "Проверьте шлейф видеоглазка", f_sub, (148, 163, 184, 255))
    else:
        raise ValueError(f"Unknown splash kind: {kind}")

    ov_1x = down(ov, box_w, box_h)
    base_rgba = base.convert("RGBA")
    base_rgba.alpha_composite(ov_1x, (box_x0, box_y0))
    return base_rgba.convert("RGB")


def _render_portrait_splash_card(kind: str) -> Image.Image:
    return _render_splash_card(kind, "portrait")


def build_mtd5_splashes(out_splash_dir: str = OUT_SPLASH_DIR, orientation: str = "portrait"):
    """
    Generate the 3 Russian 800x450 NV21 LiteOS splash buffers for mtd5:
      - splash_0_nocam.nv21   (@ 0x5592A0, 540,000 B, replaces 无法连接猫眼)
      - splash_1_upgrade.nv21 (@ 0x5DD000, 540,000 B, replaces 升级中...)
      - splash_2_boot.nv21    (@ 0x660D60, 540,000 B, replaces 小白智能猫眼)
    Returns list of (name, mtd5_offset, nv21_bytes).
    """
    assert orientation in ("portrait", "landscape")
    os.makedirs(out_splash_dir, exist_ok=True)
    specs = [
        ("splash_0_nocam", 0x5592A0, "nocam"),
        ("splash_1_upgrade", 0x5DD000, "upgrade"),
        ("splash_2_boot", 0x660D60, "boot"),
    ]
    results = []
    for name, off, kind in specs:
        im_card = _render_splash_card(kind, orientation)
        if orientation == "portrait":
            nv21 = encode_portrait_to_mtd5_nv21(im_card)
            png_suffix = "portrait_450x800"
        else:
            nv21 = encode_landscape_to_mtd5_nv21(im_card)
            png_suffix = "landscape_800x450"
        nv21_path = os.path.join(out_splash_dir, f"{name}.nv21")
        png_path = os.path.join(out_splash_dir, f"{name}_{png_suffix}.png")
        with open(nv21_path, "wb") as f:
            f.write(nv21)
        im_card.save(png_path, "PNG", optimize=True)
        results.append((name, off, nv21))
        print(f"Generated mtd5 {name} @ 0x{off:06x} ({len(nv21)} B NV21, {orientation})")
    return results


if __name__ == "__main__":
    build_modern_skin_assets()
    build_mtd5_splashes()
