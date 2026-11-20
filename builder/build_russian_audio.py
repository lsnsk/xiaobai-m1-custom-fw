import asyncio
import os
import struct
import shutil
import subprocess
import sys
import time
import wave
import miniaudio

sys.stdout.reconfigure(encoding='utf-8')

def lin2alaw_sample(pcm_val: int) -> int:
    pcm_val = max(-32768, min(32767, pcm_val))
    mask = 0xD5
    if pcm_val >= 0:
        sign = 0x80
    else:
        sign = 0x00
        pcm_val = -pcm_val - 1
        if pcm_val < 0:
            pcm_val = 0
    pcm_val >>= 3
    if pcm_val >= 256:
        seg = 7
        for s in range(1, 8):
            if pcm_val < (0x100 << s):
                seg = s
                break
        aval = (seg << 4) | ((pcm_val >> (seg + 3)) & 0x0F)
    else:
        aval = pcm_val >> 4
    return (aval | sign) ^ mask

ALAW_LUT = [lin2alaw_sample(i) for i in range(-32768, 32768)]

VOICE_SYS = "ru-RU-SvetlanaNeural"
VOICE_OUTDOOR = "ru-RU-DmitryNeural"

# (mtd5_fixed_len_or_None, voice, rate_or_None, text, cache_tag)
phrases = {
    '01_fastreply':          (19872, VOICE_OUTDOOR, None,   'Здравствуйте! Кто вы и по какому вопросу?', 'dmitry_v4'),
    '02_fastreply':          (19296, VOICE_OUTDOOR, None,   'Внимание! Ведётся видеозапись.',            'dmitry_v4'),
    '03_fastreply':          (19584, VOICE_OUTDOOR, None,   'Подождите минуту, сейчас открою.',          'dmitry_v4'),
    '04_fastreply':          (19296, VOICE_OUTDOOR, None,   'Оставьте доставку у двери.',                'dmitry_v4'),
    '5GHz_wifi_supported':   (None,  VOICE_SYS,     '+5%',  'Сеть вай-фай пять гигагерц не поддерживается. Выберите два и четыре гигагерца.', 'v2'),
    'binding_fail':          (None,  VOICE_SYS,     '+5%',  'Ошибка привязки устройства.',               'v2'),
    'binding_success':       (None,  VOICE_SYS,     '+5%',  'Устройство успешно привязано.',             'v2'),
    'booting':               (None,  VOICE_SYS,     '+5%',  'Запуск устройства, пожалуйста подождите.',  'v2'),
    'connecting_pease_wait': (None,  VOICE_SYS,     '+5%',  'Подключение к сети, пожалуйста подождите.', 'v2'),
    'error':                 (None,  VOICE_SYS,     '+5%',  'Произошла ошибка.',                         'v2'),
    'qrcode_success':        (None,  VOICE_SYS,     '+5%',  'Кью-ар код успешно распознан.',             'v2'),
    'qrcode_supported':      (None,  VOICE_SYS,     '+5%',  'Покажите кью-ар код камере глазка.',        'v2'),
    'reset_success':         (None,  VOICE_SYS,     '+5%',  'Заводские настройки восстановлены.',        'v2'),
    'waiting_connection':    (None,  VOICE_SYS,     '+5%',  'Ожидание подключения.',                     'v2'),
    'wifi_connected':        (None,  VOICE_SYS,     '+5%',  'Вай-фай успешно подключён.',                'v2'),
    '_power_off':            (12384, VOICE_SYS,     '+20%', 'Устройство выключается.',                   'v2'),
    '_power_on':             (21024, VOICE_SYS,     '+10%', 'Видеоглазок включён.',                      'v2'),
}

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
out_sound_dir = os.path.join(BASE_DIR, 'out_patch', 'sound')
out_mtd5_dir  = os.path.join(BASE_DIR, 'out_patch', 'sound_mtd5')
tts_mp3_dir   = os.path.join(BASE_DIR, 'tts_mp3')
os.makedirs(out_sound_dir, exist_ok=True)
os.makedirs(out_mtd5_dir, exist_ok=True)
os.makedirs(tts_mp3_dir, exist_ok=True)

async def synth_mp3_to_alaw(mp3_path: str, text: str, voice: str, rate_str):
    for attempt in range(25):
        if os.path.exists(mp3_path) and os.path.getsize(mp3_path) > 500:
            break
        try:
            cmd = [sys.executable, "-m", "edge_tts", "--voice", voice, "--text", text, "--write-media", mp3_path]
            if rate_str:
                cmd.extend([f"--rate={rate_str}"])
            subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=20)
            if os.path.exists(mp3_path) and os.path.getsize(mp3_path) > 500:
                await asyncio.sleep(1.2)
                break
        except Exception as e:
            if os.path.exists(mp3_path) and os.path.getsize(mp3_path) < 500:
                os.remove(mp3_path)
            print(f"  Retry {attempt+1} for {os.path.basename(mp3_path)}: {e}")
            await asyncio.sleep(3.5)

    decoded = miniaudio.decode_file(
        mp3_path,
        output_format=miniaudio.SampleFormat.SIGNED16,
        nchannels=1,
        sample_rate=8000,
    )
    samples = list(decoded.samples)
    peak = max((abs(s) for s in samples), default=1)
    gain = min(2.6, 27500.0 / max(peak, 1))
    samples = [max(-32768, min(32767, int(s * gain))) for s in samples]

    st = 0
    while st < len(samples) and abs(samples[st]) < 200:
        st += 1
    st = max(0, st - 200)
    en = len(samples)
    while en > st and abs(samples[en - 1]) < 200:
        en -= 1
    en = min(len(samples), en + 320)

    trimmed = samples[st:en]
    alaw = bytes(ALAW_LUT[s + 32768] for s in trimmed)
    return trimmed, alaw

def compress_pauses_and_fit(pcm: list[int], target_len: int) -> bytes:
    # First trim inter-word pauses longer than 70ms (560 samples) so speech stays crisp without pitch shift
    out = []
    quiet_run = 0
    for s in pcm:
        if abs(s) < 300:
            quiet_run += 1
            if quiet_run <= 560:
                out.append(s)
        else:
            quiet_run = 0
            out.append(s)
    if len(out) > target_len:
        # Gentle linear decimation if still slightly over target_len
        n_in = len(out)
        out = [out[int(i * n_in / target_len)] for i in range(target_len)]
    alaw = bytes(ALAW_LUT[s + 32768] for s in out)
    if len(alaw) < target_len:
        alaw = alaw + b'\xd5' * (target_len - len(alaw))
    return alaw[:target_len]

def save_wav_preview(wav_path: str, pcm_samples: list[int]):
    with wave.open(wav_path, 'wb') as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(8000)
        wf.writeframes(struct.pack(f'<{len(pcm_samples)}h', *pcm_samples))

async def synth_all():
    for name, (fixed_len, voice, rate_str, text, tag) in phrases.items():
        mp3_name = f"{name}_{tag}.mp3" if tag != 'v2' else f"{name}_v2.mp3"
        mp3_path = os.path.join(tts_mp3_dir, mp3_name)
        pcm, alaw = await synth_mp3_to_alaw(mp3_path, text, voice, rate_str)
        raw_dur = len(alaw) / 8000.0

        if not name.startswith('_power_'):
            rootfs_alaw = b'\xd5' * 320 + alaw + b'\xd5' * 640
            with open(os.path.join(out_sound_dir, name), 'wb') as f:
                f.write(rootfs_alaw)
            if name.startswith(('01_', '02_', '03_', '04_')):
                save_wav_preview(os.path.join(BASE_DIR, f'ru_preview_{name}.wav'), pcm)

        if fixed_len is not None:
            m_alaw = compress_pauses_and_fit(pcm, fixed_len)
            with open(os.path.join(out_mtd5_dir, name), 'wb') as f:
                f.write(m_alaw)
            print(f"[edge-tts] {name:22s} ({voice.split('-')[-1]}): rootfs={raw_dur:.2f}s ({len(alaw)}B), mtd5={fixed_len}B | '{text}'")
        else:
            print(f"[edge-tts] {name:22s} ({voice.split('-')[-1]}): rootfs={raw_dur:.2f}s | '{text}'")

    shutil.copyfile(os.path.join(BASE_DIR, 'squashfs-root', 'app', 'sound', 'ding'), os.path.join(out_sound_dir, 'ding'))
    with open(os.path.join(out_sound_dir, 'README'), 'w', encoding='utf-8', newline='\n') as f:
        f.write("fast reply (ru-RU-DmitryNeural)\n"
                "1 Здравствуйте! Кто вы и по какому вопросу?\n"
                "2 Внимание! Ведётся видеозапись.\n"
                "3 Подождите минуту, сейчас открою.\n"
                "4 Оставьте доставку у двери.\n")

if __name__ == '__main__':
    asyncio.run(synth_all())
