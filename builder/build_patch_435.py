import hashlib
import os
import shutil
import struct
import subprocess
import sys
import zlib
from build_ubf_fonts import build_all_fonts
from build_lang_files import build_all_langs
from build_modern_skin import build_modern_skin_assets, build_mtd5_splashes
from build_portrait_ui import (
    build_landscape_higv,
    build_portrait_higv,
    patch_main_app_landscape,
    patch_main_app_portrait,
)

sys.stdout.reconfigure(encoding="utf-8")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
WSL_BASE_DIR = (
    "/mnt/" + BASE_DIR[0].lower() + BASE_DIR[2:].replace("\\", "/")
    if len(BASE_DIR) >= 2 and BASE_DIR[1] == ":"
    else BASE_DIR.replace("\\", "/")
)
OUT_LEGACY = os.path.join(BASE_DIR, "out_patch_435")
OUT_PORTRAIT = os.path.join(BASE_DIR, "out_patch_435_portrait")
OUT_LANDSCAPE = os.path.join(BASE_DIR, "out_patch_435_landscape")
CONF_TEMPLATE_PATH = os.path.join(OUT_LEGACY, "eye.conf.example")

for d in (OUT_LEGACY, OUT_PORTRAIT, OUT_LANDSCAPE):
    os.makedirs(d, exist_ok=True)


def md5_file(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(131072), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def build_base_main_app() -> bytearray:
    with open(os.path.join(BASE_DIR, r"rootfs_435_extracted\main_app"), "rb") as f:
        main_data = bytearray(f.read())

    replacements = [
        (0x2341D3, "录像日期 %04d-%02d-%02d", "Дата: %04d-%02d-%02d"),
        (0x234209, "录像个数 %d",             "Видео: %d"),
        (0x234F5B, "无操作%u秒钟后",          "Через %u сек"),
        (0x236AE4, "%.2fG已用(共%.2fG)",      "%.2fG / %.2fG"),
        (0x2378DF, "已开启",                  "Вкл."),
        (0x2378ED, "已关闭",                  "Выкл"),
    ]
    for off, orig_str, new_str in replacements:
        orig_b = orig_str.encode("utf-8") + b"\x00"
        new_b = new_str.encode("utf-8") + b"\x00"
        assert main_data[off : off + len(orig_b)] == orig_b, f"Mismatch at {hex(off)}"
        assert len(new_b) <= len(orig_b), f"Too long at {hex(off)}"
        padded = new_b + b"\x00" * (len(orig_b) - len(new_b))
        main_data[off : off + len(orig_b)] = padded
        print(f"Patched 4.3.5 main_app @ {hex(off)}: {orig_str!r} -> {new_str!r}")

    # Fix HI_FSTOOL_Format for full 64/128/256GB SDXC & Windows MBR Type 0x0B (Win95 FAT32) compatibility
    assert main_data[0x08F5F4:0x08F5F8] == bytes.fromhex("12 00 00 0a"), "Mismatch at 0x08f5f4"
    main_data[0x08F5F4:0x08F5F8] = bytes.fromhex("00 00 a0 e1")
    orig_fdisk = b'echo -e "d\n1\nd\n2\nd\n3\nd\nn\np\n1\n\n\n\n\nx\nb\n1\n2048\nY\nw\n" | fdisk \x00\x00'
    new_fdisk  = b'echo -e "d\n1\nd\n2\nd\n3\nd\nn\np\n1\n\n\nt\nb\nx\nb\n1\n2048\nY\nw\n"|fdisk \x00\x00'
    assert len(orig_fdisk) == len(new_fdisk) == 60
    assert main_data[0x245528 : 0x245528 + 60] == orig_fdisk, "Mismatch at 0x245528"
    main_data[0x245528 : 0x245528 + 60] = new_fdisk
    print("Patched 4.3.5 main_app HI_FSTOOL_Format (full 64/128/256GB + MBR 0x0B Win95 FAT32 fix)")

    # Remove hardcoded China UTC+8 (+/-28800s) offsets so Linux runs in true UTC and HW RTC/LiteOS OSD use local wall-clock time
    clock_patches = [
        # 1. Home Screen top-bar clock (wid=445): remove -28800 before localtime_r
        (0x02BCF0, 0xE2403A07, 0xE1A03000),  # VA 0x03BCF0: SUB r3, r0, #0x7000 -> MOV r3, r0
        (0x02BCF8, 0xE2433080, 0xE1A00000),  # VA 0x03BCF8: SUB r3, r3, #0x80   -> NOP
        # 2. HI_SYSTEM_SetDateTime: remove +28800 before settimeofday & -28800 before ctime log
        (0x06EEC8, 0xE2800A07, 0xE1A00000),  # VA 0x07EEC8: ADD r0, r0, #0x7000 -> NOP
        (0x06EED0, 0xE2800080, 0xE1A00000),  # VA 0x07EED0: ADD r0, r0, #0x80   -> NOP
        (0x06EF64, 0xE2433A07, 0xE1A00000),  # VA 0x07EF64: SUB r3, r3, #0x7000 -> NOP
        (0x06EF68, 0xE2433080, 0xE1A00000),  # VA 0x07EF68: SUB r3, r3, #0x80   -> NOP
        # 3. MP4 record creat_time: keep -6s pre-roll, remove -28800 China offset
        (0x0124B8, 0xE2400A07, 0xE1A00000),  # VA 0x0224B8: SUB r0, r0, #0x7000 -> NOP
        (0x0124C4, 0xE2400086, 0xE2400006),  # VA 0x0224C4: SUB r0, r0, #134    -> SUB r0, r0, #6
        # 4. Event / cloud epoch timestamps: remove -28800 from time(NULL)
        (0x19EE14, 0xE2400A07, 0xE1A00000),  # VA 0x1AEE14
        (0x19EE18, 0xE2400080, 0xE1A00000),  # VA 0x1AEE18
        (0x19EFF0, 0xE2403A07, 0xE1A03000),  # VA 0x1AEFF0
        (0x19EFF4, 0xE2433080, 0xE1A00000),  # VA 0x1AEFF4
        (0x1A0218, 0xE2406A07, 0xE1A06000),  # VA 0x1B0218
        (0x1A0228, 0xE2466080, 0xE1A00000),  # VA 0x1B0228
        (0x1A02FC, 0xE2450A07, 0xE1A00005),  # VA 0x1B02FC
        (0x1A0300, 0xE2400080, 0xE1A00000),  # VA 0x1B0300
    ]
    for foff, orig_w, new_w in clock_patches:
        got_w = struct.unpack_from("<I", main_data, foff)[0]
        assert got_w == orig_w, f"Clock patch mismatch at {hex(foff)}: got {hex(got_w)} != {hex(orig_w)}"
        struct.pack_into("<I", main_data, foff, new_w)
    print(f"Patched 4.3.5 main_app clock offsets ({len(clock_patches)} ARM words, +/-28800s removed)")
    return main_data


def build_base_mtd5() -> tuple[bytes, bytearray]:
    with open(os.path.join(BASE_DIR, r"backup_4.3.5_3319\mtd5_media_app_zip.bin"), "rb") as f:
        zdata = f.read()
    gz_len, raw_len, magic = struct.unpack_from("<II8s", zdata, 0)
    assert magic == b"gziphead"
    orig_gz_hdr = zdata[16 : 16 + 24]
    raw435 = bytearray(zlib.decompress(zdata[16 : 16 + gz_len], 16 + zlib.MAX_WBITS))
    assert len(raw435) == raw_len

    media_patches = [
        ("01_fastreply", 0x541689, 19872),
        ("02_fastreply", 0x546430, 19296),
        ("03_fastreply", 0x54AF94, 19584),
        ("04_fastreply", 0x54FC18, 19296),
        ("_power_off",   0x7A932C, 12384),
        ("_power_on",    0x7AC390, 21024),
    ]
    for name, off, length in media_patches:
        snd_path = os.path.join(BASE_DIR, r"out_patch\sound_mtd5", name)
        if not os.path.isfile(snd_path):
            snd_path = os.path.join(BASE_DIR, r"out_patch\sound", name)
        with open(snd_path, "rb") as f:
            snd_bytes = f.read()
        snd_bytes = snd_bytes + b"\xd5" * max(0, length - len(snd_bytes))
        raw435[off : off + length] = snd_bytes[:length]
        print(f"Patched 4.3.5 media_app_raw @ {hex(off)} ({length} B) with {name}")
    return orig_gz_hdr, raw435


def compress_mtd5(orig_gz_hdr: bytes, raw_buf: bytes, out_path: str):
    # HiSilicon hardware ugzip (go_cpu1) strictly requires 8 KiB window (wbits = -13) + 24-byte FNAME header
    comp = zlib.compressobj(9, zlib.DEFLATED, -13, 9)
    deflated = comp.compress(raw_buf) + comp.flush()
    crc = zlib.crc32(raw_buf) & 0xFFFFFFFF
    gz_out = orig_gz_hdr + deflated + struct.pack("<II", crc, len(raw_buf))
    assert zlib.decompress(gz_out[24:-8], -13) == raw_buf
    media_zip_out = struct.pack("<II", len(gz_out), len(raw_buf)) + b"gziphead" + gz_out
    assert len(media_zip_out) <= 0x2E0000, f"media_app_zip too large: {len(media_zip_out)}"
    with open(out_path, "wb") as f:
        f.write(media_zip_out)
    print(f"Saved {out_path}: {len(media_zip_out)} bytes (limit {0x2E0000})")


def write_variant_conf_example(template_txt: str, variant: str, out_dir: str):
    if variant == "landscape":
        old_blk = (
            "# --- 3. Ориентация экрана и камеры (для узкого места на двери) ---\n"
            "# Поворот внутреннего экрана видеопотока: 90 (по часовой стрелке — по умолчанию), 270 (против часовой), 0, 180\n"
            "VO_ROTATE=90\n"
            "# Поворот сохраняемых .mp4 и .jpeg (1080x1920 9:16): 90 (по часовой стрелке), 270, 0, 180\n"
            "CAM_ROTATE=90"
        )
        new_blk = (
            "# --- 3. Ориентация камеры и записей (горизонтальная прошивка 854x480) ---\n"
            "# Поворот наружной камеры и сохраняемых .mp4/.jpeg: 0 = штатно горизонтально 1920x1080 (16:9), 90, 270, 180\n"
            "CAM_ROTATE=0\n"
            "# Аппаратный поворот видеослоя матрицы (90 = штатно для горизонтального экрана; меняется автоматически кнопкой поворота)\n"
            "VO_ROTATE=90"
        )
        txt = template_txt.replace(old_blk, new_blk).replace("вертикальное видео .mp4", "видео .mp4")
    else:
        txt = template_txt
    out_p = os.path.join(out_dir, "eye.conf.example")
    with open(out_p, "w", encoding="utf-8", newline="\n") as f:
        f.write(txt)


def ensure_lf_scripts():
    targets = [
        os.path.join(BASE_DIR, "pack_435_wsl.sh"),
        os.path.join(BASE_DIR, r"openwrt\eye_openwrt_bot.sh"),
        os.path.join(BASE_DIR, r"openwrt\eye_keepalive.sh"),
        os.path.join(BASE_DIR, r"openwrt\eye-bot.init"),
        os.path.join(BASE_DIR, r"openwrt\eye-bot.conf"),
    ]
    for root, _, files in os.walk(os.path.join(BASE_DIR, "eye_addon")):
        for fn in files:
            if fn.endswith((".sh", ".cgi", ".default")):
                targets.append(os.path.join(root, fn))
    for lf_path in targets:
        if os.path.isfile(lf_path):
            with open(lf_path, "rb") as f_in:
                raw = f_in.read()
            fixed = raw.replace(b"\r\n", b"\n")
            if fixed != raw:
                with open(lf_path, "wb") as f_out:
                    f_out.write(fixed)


def ensure_native_tools():
    """Rebuild static ARM Cortex-A7 binaries via WSL cross-gcc whenever sources are newer."""
    stb_h = os.path.join(BASE_DIR, "stb_image_write.h")
    tool_src = [os.path.join(BASE_DIR, "eye_tool.c"), stb_h]
    tool_bin = os.path.join(OUT_LEGACY, "eye_tool")
    need_tool = (not os.path.isfile(tool_bin)) or any(
        os.path.isfile(s) and os.path.getmtime(s) > os.path.getmtime(tool_bin) for s in tool_src
    )
    if need_tool:
        print("Recompiling static ARM eye_tool via WSL arm-linux-musleabi-gcc...")
        subprocess.run(
            [
                "wsl", "bash", "-lc",
                f'cd "{WSL_BASE_DIR}" && "${{XIAOBAI_CROSS_DIR:-$HOME/arm-linux-musleabi-cross}}/bin/arm-linux-musleabi-gcc" '
                '-mcpu=cortex-a7 -O2 -s -static -fmacro-prefix-map="${XIAOBAI_DEPS_DIR:-$HOME/deps}/include=deps" '
                '-I"${XIAOBAI_DEPS_DIR:-$HOME/deps}/include" '
                '-I"${XIAOBAI_DEPS_DIR:-$HOME/deps}/include/opus" -I. '
                'eye_tool.c -o out_patch_435/eye_tool "${XIAOBAI_DEPS_DIR:-$HOME/deps}/lib/libopus.a" -lm',
            ],
            check=True,
        )

    snap_src = [os.path.join(BASE_DIR, "eye_snap.c"), stb_h]
    snap_bin = os.path.join(OUT_LEGACY, "eye_snap")
    need_snap = (not os.path.isfile(snap_bin)) or any(
        os.path.isfile(s) and os.path.getmtime(s) > os.path.getmtime(snap_bin) for s in snap_src
    )
    if need_snap:
        print("Recompiling static ARM eye_snap via WSL arm-linux-musleabi-gcc...")
        subprocess.run(
            [
                "wsl", "bash", "-lc",
                f'cd "{WSL_BASE_DIR}" && "${{XIAOBAI_CROSS_DIR:-$HOME/arm-linux-musleabi-cross}}/bin/arm-linux-musleabi-gcc" '
                '-mcpu=cortex-a7 -O2 -s -static -I. eye_snap.c -o out_patch_435/eye_snap -lm',
            ],
            check=True,
        )


def build_variant(variant: str, out_dir: str, base_main: bytearray, orig_gz_hdr: bytes, base_mtd5: bytearray, conf_tmpl: str):
    print(f"\n==================== BUILDING VARIANT: {variant.upper()} ({out_dir}) ====================")
    os.makedirs(out_dir, exist_ok=True)
    pic_dir = os.path.join(out_dir, "res_pic")
    splash_dir = os.path.join(out_dir, "mtd5_splashes")

    build_modern_skin_assets(pic_dir, orientation=variant)

    main_copy = bytearray(base_main)
    higv_path = os.path.join(out_dir, "higv.bin")
    if variant == "portrait":
        build_portrait_higv(higv_path)
        patch_main_app_portrait(main_copy)
    else:
        build_landscape_higv(higv_path)
        patch_main_app_landscape(main_copy)

    with open(os.path.join(out_dir, "main_app"), "wb") as f:
        f.write(main_copy)

    mtd5_copy = bytearray(base_mtd5)
    for splash_name, splash_off, splash_nv21 in build_mtd5_splashes(splash_dir, orientation=variant):
        assert len(splash_nv21) == 540000
        mtd5_copy[splash_off : splash_off + 540000] = splash_nv21
        print(f"Patched 4.3.5 media_app_raw @ {hex(splash_off)} (540000 B NV21) with {splash_name} ({variant})")

    media_zip_path = os.path.join(out_dir, "media_app_zip.bin")
    compress_mtd5(orig_gz_hdr, bytes(mtd5_copy), media_zip_path)

    write_variant_conf_example(conf_tmpl, variant, out_dir)

    subprocess.run(["wsl", "bash", f"{WSL_BASE_DIR}/pack_435_wsl.sh", variant], check=True)

    sq_path = os.path.join(out_dir, "rootfs.squashfs")
    sq_sz = os.path.getsize(sq_path)
    md_sz = os.path.getsize(media_zip_path)
    assert sq_sz <= 0x800000, f"{variant} rootfs.squashfs too large: {sq_sz}"
    assert md_sz <= 0x2E0000, f"{variant} media_app_zip.bin too large: {md_sz}"

    uimage_src = os.path.join(BASE_DIR, r"backup_4.3.5_3319\mtd6_uImage")
    uimage_dst = os.path.join(out_dir, "uImage.bin")
    shutil.copy2(uimage_src, uimage_dst)

    install_doc = os.path.join(BASE_DIR, "INSTALL_RU.md")
    if os.path.isfile(install_doc):
        shutil.copy2(install_doc, os.path.join(out_dir, "INSTALL_RU.md"))

    md5_media = md5_file(media_zip_path)
    md5_uimg = md5_file(uimage_dst)
    md5_sq = md5_file(sq_path)
    with open(os.path.join(out_dir, "MD5SUMS.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write(f"{md5_media.lower()}  media_app_zip.bin\n")
        f.write(f"{md5_uimg.lower()}  uImage.bin\n")
        f.write(f"{md5_sq.lower()}  rootfs.squashfs\n")

    print(
        f"OK [{variant}]:\n"
        f"  media_app_zip.bin = {md_sz:,} B ({md_sz/1024/1024:.2f} MB <= 2.88 MB) MD5={md5_media}\n"
        f"  uImage.bin        = {os.path.getsize(uimage_dst):,} B (3.00 MB) MD5={md5_uimg}\n"
        f"  rootfs.squashfs   = {sq_sz:,} B ({sq_sz/1024/1024:.2f} MB <= 8.00 MB) MD5={md5_sq}"
    )
    return md_sz, md5_media, sq_sz, md5_sq


def main():
    ensure_lf_scripts()
    ensure_native_tools()
    build_all_fonts()
    build_all_langs()

    with open(CONF_TEMPLATE_PATH, "r", encoding="utf-8") as f:
        conf_tmpl = f.read().replace("\r\n", "\n")

    base_main = build_base_main_app()
    orig_gz_hdr, base_mtd5 = build_base_mtd5()

    build_variant("landscape", OUT_LANDSCAPE, base_main, orig_gz_hdr, base_mtd5, conf_tmpl)
    build_variant("portrait", OUT_PORTRAIT, base_main, orig_gz_hdr, base_mtd5, conf_tmpl)

    # Mirror portrait artifacts into out_patch_435/ so existing workflows remain 100% compatible
    for fn in ("media_app_zip.bin", "uImage.bin", "rootfs.squashfs", "main_app", "higv.bin", "MD5SUMS.txt", "INSTALL_RU.md"):
        shutil.copy2(os.path.join(OUT_PORTRAIT, fn), os.path.join(OUT_LEGACY, fn))
    if os.path.isdir(os.path.join(OUT_LEGACY, "res_pic")):
        shutil.rmtree(os.path.join(OUT_LEGACY, "res_pic"))
    shutil.copytree(os.path.join(OUT_PORTRAIT, "res_pic"), os.path.join(OUT_LEGACY, "res_pic"))
    if os.path.isdir(os.path.join(OUT_LEGACY, "mtd5_splashes")):
        shutil.rmtree(os.path.join(OUT_LEGACY, "mtd5_splashes"))
    shutil.copytree(os.path.join(OUT_PORTRAIT, "mtd5_splashes"), os.path.join(OUT_LEGACY, "mtd5_splashes"))

    print("\nALL DONE! Built both out_patch_435_landscape (854x480) and out_patch_435_portrait (480x854).")


if __name__ == "__main__":
    main()
