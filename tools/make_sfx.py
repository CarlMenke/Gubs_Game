"""Synthesise the game's sound effects from scratch.

There is no sound library for this project and no budget for one, so the effects
are generated rather than recorded. That is not a compromise for a game that
looks like this: a Gub is a cartoon, and short synthetic hits — a filtered noise
whoosh, a low thud, a struck-glass chime — read as deliberate stylisation where
a mismatched library sample would read as an accident.

Generating them also means they are diffable, tunable from a single number, and
reproducible on any machine, which is the same argument made for the mesh
pipeline in D-003 and the ragdoll in D-006.

Everything is written as 16-bit mono 44.1 kHz WAV. Godot imports .wav without
any extra configuration, and every clip here is well under a second, so the size
saved by encoding to Ogg would be measured in kilobytes and cost the ability to
loop them sample-exactly.

Usage:  python tools/make_sfx.py
"""

import os
import struct
import wave

import numpy as np

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(REPO, "audio", "sfx")
AMBIENCE_DIR = os.path.join(REPO, "audio", "ambience")

RATE = 44100
## Ambience beds are all low-frequency wash with nothing above a few kHz, so
## half the sample rate costs nothing audible and halves the file.
AMBIENCE_RATE = 22050


def envelope(n, attack, decay, curve=2.0):
    """Amplitude envelope over `n` samples.

    `attack` and `decay` are fractions of the whole clip. The decay is raised to
    `curve` so it falls away fast at first and then tails off, which is what
    makes a hit sound struck rather than faded.
    """
    out = np.ones(n)
    a = max(1, int(n * attack))
    d = max(1, int(n * decay))
    out[:a] = np.linspace(0.0, 1.0, a)
    out[n - d:] = np.linspace(1.0, 0.0, d) ** curve
    return out


def noise(n, seed):
    """Reproducible white noise. A fixed seed keeps re-runs byte-identical."""
    return np.random.default_rng(seed).uniform(-1.0, 1.0, n)


def lowpass(signal, cutoff_hz):
    """One-pole low-pass. Crude, and exactly right for taking the fizz off
    noise without pulling in scipy for four sound effects."""
    alpha = 1.0 - np.exp(-2.0 * np.pi * cutoff_hz / RATE)
    out = np.empty_like(signal)
    state = 0.0
    for i in range(len(signal)):
        state += alpha * (signal[i] - state)
        out[i] = state
    return out


def sweep(n, start_hz, end_hz, curve=1.0):
    """A sine whose pitch glides from `start_hz` to `end_hz`."""
    t = np.linspace(0.0, 1.0, n)
    freq = start_hz + (end_hz - start_hz) * (t ** curve)
    # Integrate frequency to get phase, or the sweep detunes as it goes.
    phase = np.cumsum(2.0 * np.pi * freq / RATE)
    return np.sin(phase)


def seconds(duration):
    return int(RATE * duration)


def normalise(signal, peak=0.85):
    """Scale to a fixed peak so no clip is wildly louder than its neighbours."""
    high = np.max(np.abs(signal))
    if high < 1e-9:
        return signal
    return signal / high * peak


def write(name, signal, directory=None, rate=RATE, peak=0.85):
    directory = directory or OUT_DIR
    if not os.path.isdir(directory):
        os.makedirs(directory)
    data = np.clip(normalise(signal, peak), -1.0, 1.0)
    pcm = (data * 32767.0).astype("<i2")
    path = os.path.join(directory, "%s.wav" % name)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(pcm.tobytes())
    print("  %-18s %5.2fs  %5d KB" % (name, len(data) / rate, os.path.getsize(path) // 1024))


# --------------------------------------------------------------- ambience ---

def looping_noise(n, low_hz, high_hz, seed):
    """Noise that loops perfectly, band-limited between two frequencies.

    Built in the frequency domain rather than filtered in the time domain. Every
    component is an exact whole number of cycles across the buffer, so the last
    sample runs into the first with no discontinuity — which is the entire
    problem with looping an ambience bed. Crossfading the ends of ordinary noise
    hides the seam; this one has no seam to hide.
    """
    rng = np.random.default_rng(seed)
    spectrum = np.zeros(n // 2 + 1, dtype=complex)
    freqs = np.fft.rfftfreq(n, 1.0 / AMBIENCE_RATE)
    band = (freqs >= low_hz) & (freqs <= high_hz)
    # 1/f inside the band: white noise sounds like static, pink like weather.
    magnitude = np.zeros_like(freqs)
    magnitude[band] = 1.0 / np.maximum(freqs[band], 1.0)
    phase = rng.uniform(0.0, 2.0 * np.pi, len(freqs))
    spectrum = magnitude * np.exp(1j * phase)
    return np.fft.irfft(spectrum, n)


def looping_swell(n, cycles, depth=0.45):
    """A slow amplitude drift that also closes its own loop, because it is built
    from whole numbers of cycles across the buffer."""
    t = np.linspace(0.0, 2.0 * np.pi, n, endpoint=False)
    return 1.0 - depth + depth * (0.5 + 0.5 * np.sin(cycles * t))


def ambient_wind():
    """The bed under everything: air moving through a lot of leaves."""
    n = int(AMBIENCE_RATE * 12.0)
    body = looping_noise(n, 40.0, 900.0, 11)
    # A brighter layer that swells on a different period, so the two never line
    # up and the loop does not announce itself every twelve seconds.
    body += 0.35 * looping_noise(n, 700.0, 4200.0, 12) * looping_swell(n, 3)
    return body * looping_swell(n, 2, 0.5)


def ambient_forest():
    """Night in the hollow. Low drone, a slow shimmer above it, and no events —
    anything that reads as a distinct sound would repeat on the loop and become
    the only thing anyone can hear."""
    n = int(AMBIENCE_RATE * 16.0)
    t = np.linspace(0.0, n / AMBIENCE_RATE, n, endpoint=False)
    bed = 0.7 * looping_noise(n, 30.0, 500.0, 21) * looping_swell(n, 2, 0.35)
    shimmer = 0.5 * looping_noise(n, 2000.0, 7000.0, 22) * looping_swell(n, 5, 0.6)
    # Two quiet drones a fifth apart, at exact whole cycles across the buffer.
    drone = np.zeros(n)
    for cycles, gain in [(round(55.0 * n / AMBIENCE_RATE), 0.30),
                         (round(82.5 * n / AMBIENCE_RATE), 0.18)]:
        drone += gain * np.sin(2.0 * np.pi * cycles * t / (n / AMBIENCE_RATE))
    return bed + shimmer + drone * 0.35


AMBIENCE = {
    "ambient_wind": ambient_wind,
    "ambient_forest": ambient_forest,
}


# ----------------------------------------------------------------- effects ---

def spear_throw():
    """Air moving past a stick: noise, low-passed, swelling then gone."""
    n = seconds(0.32)
    body = lowpass(noise(n, 1), 1800.0)
    # A second, brighter layer swept downward gives the whoosh a direction.
    body += 0.4 * lowpass(noise(n, 2), 5200.0) * np.linspace(1.0, 0.2, n)
    return body * envelope(n, 0.22, 0.7, 2.2)


def spear_hit_body():
    """A wet, low thud. Almost all of this is the 90 Hz thump; the noise on top
    is just enough transient to stop it sounding like a drum machine."""
    n = seconds(0.26)
    thump = sweep(n, 150.0, 62.0, 0.5) * envelope(n, 0.005, 0.9, 2.6)
    slap = lowpass(noise(n, 3), 900.0) * envelope(n, 0.002, 0.35, 4.0) * 0.55
    return thump + slap


def spear_hit_world():
    """Wood into dirt: shorter and harder than a body hit, with a bit of ring."""
    n = seconds(0.22)
    knock = sweep(n, 420.0, 180.0, 0.6) * envelope(n, 0.003, 0.85, 3.2)
    grit = lowpass(noise(n, 4), 3000.0) * envelope(n, 0.002, 0.25, 5.0) * 0.7
    return knock + grit


def spear_ready():
    """The spear growing back in the hand. Rising, soft, unmistakably 'again'."""
    n = seconds(0.30)
    return sweep(n, 320.0, 780.0, 1.4) * envelope(n, 0.25, 0.6, 1.6) * 0.8


def mushroom_deploy():
    """Something organic shoving itself out of the ground: a pitch rise with a
    thick low body under it."""
    n = seconds(0.45)
    swell = sweep(n, 90.0, 240.0, 1.8) * envelope(n, 0.12, 0.6, 1.8)
    squelch = lowpass(noise(n, 5), 1400.0) * envelope(n, 0.05, 0.8, 2.0) * 0.45
    return swell + squelch


def lure_throw():
    """A struck crystal, thrown. Three partials at inharmonic ratios — whole
    number ratios sound like a musical note, and this should sound like glass."""
    n = seconds(0.5)
    t = np.linspace(0.0, n / RATE, n)
    tone = np.zeros(n)
    for freq, gain, decay in [(880.0, 1.0, 7.0), (1490.0, 0.5, 9.0), (2310.0, 0.28, 12.0)]:
        tone += gain * np.sin(2.0 * np.pi * freq * t) * np.exp(-decay * t)
    return tone * envelope(n, 0.002, 0.4, 1.5)


def lure_arm():
    """The fuse. A rising tone is the one shape everybody already reads as
    'something is about to happen', which is the whole job of this sound."""
    n = seconds(0.5)
    tone = sweep(n, 520.0, 1250.0, 2.2)
    # A shimmer an octave up, fading in, so it brightens as it climbs.
    tone += 0.35 * sweep(n, 1040.0, 2500.0, 2.2) * np.linspace(0.0, 1.0, n)
    return tone * envelope(n, 0.08, 0.25, 1.2)


def lure_fire():
    """The pull. Downward sweep — everything is being dragged inward — with a
    noise swell riding it."""
    n = seconds(0.7)
    pull = sweep(n, 1400.0, 180.0, 1.6) * envelope(n, 0.02, 0.55, 1.8)
    wind = lowpass(noise(n, 6), 2200.0) * envelope(n, 0.3, 0.5, 1.5) * 0.5
    return pull + wind


def death():
    """A Gub expiring. Falling, slightly comic, over quickly."""
    n = seconds(0.55)
    cry = sweep(n, 640.0, 150.0, 1.9) * envelope(n, 0.02, 0.7, 1.7)
    # A little vibrato keeps it from sounding like a test tone.
    t = np.linspace(0.0, n / RATE, n)
    cry *= 1.0 + 0.12 * np.sin(2.0 * np.pi * 11.0 * t)
    return cry


def respawn():
    """Back in the world: bright, rising, and clearly not a death."""
    n = seconds(0.6)
    t = np.linspace(0.0, n / RATE, n)
    tone = np.zeros(n)
    for freq, gain in [(523.0, 1.0), (784.0, 0.7), (1046.0, 0.5)]:
        # Each partial enters a little later, so it blooms rather than blares.
        start = 0.10 * (freq / 523.0 - 1.0)
        gate = (t > start).astype(float)
        tone += gain * np.sin(2.0 * np.pi * freq * t) * gate
    return tone * envelope(n, 0.06, 0.65, 1.8)


def hitmarker():
    """The click that says your spear connected. Must be very short and cut
    through everything else, so it is high and almost pure transient."""
    n = seconds(0.09)
    return sweep(n, 2400.0, 1500.0, 1.0) * envelope(n, 0.002, 0.9, 3.5)


EFFECTS = {
    "spear_throw": spear_throw,
    "spear_hit_body": spear_hit_body,
    "spear_hit_world": spear_hit_world,
    "spear_ready": spear_ready,
    "mushroom_deploy": mushroom_deploy,
    "lure_throw": lure_throw,
    "lure_arm": lure_arm,
    "lure_fire": lure_fire,
    "death": death,
    "respawn": respawn,
    "hitmarker": hitmarker,
}


def main():
    print("writing to audio/sfx/")
    for name in sorted(EFFECTS):
        write(name, EFFECTS[name]())
    print("writing to audio/ambience/")
    for name in sorted(AMBIENCE):
        # Ambience sits under the game rather than on top of it, so it is
        # normalised well below the effects.
        write(name, AMBIENCE[name](), AMBIENCE_DIR, AMBIENCE_RATE, peak=0.55)
    print("done.")


if __name__ == "__main__":
    main()
