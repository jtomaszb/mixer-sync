#!/usr/bin/env python3
"""clean_raw.py — verify processed files against the raw originals, then clean raw.

For every raw file sync.sh turns into a processed file, prove that nothing was
lost before offering to remove it:

  * the processed file exists, is 24-bit PCM, and has the expected channels/rate
  * its audio equals the raw audio times a single gain (the normalize step), to
    within 24-bit rounding: gain is fitted from RMS, the raw is scaled by it and
    subtracted from the processed audio, and the residual must be near the
    24-bit noise floor (a 16-bit copy, a wrong gain or damaged audio all fail)
  * if the processed file is shorter (trimmed silence), the raw audio past the
    cut is actually silent

Only raw files that pass every check are touched. Anything else is reported and
kept. Default is a dry run; pass --delete (or --trash) to act.

Removed files are listed in <raw>/.cleaned, which sync.sh passes to rsync so a
card that still holds them doesn't get re-copied.
"""

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path

TR = re.compile(r"^(.+_[Tt][Rr])([0-9]+)(\.wav)$")  # same pattern as sync.sh
ASTATS = "astats=measure_perchannel=none:measure_overall=Peak_level+RMS_level+Number_of_samples"
MANIFEST = ".cleaned"


class VerifyError(Exception):
    """A check failed; the message says why the raw files are being kept."""


@dataclass
class Item:
    """One processed output and the raw file(s) it was built from."""
    proc: Path
    raws: list
    session: str
    status: str = "pending"
    detail: str = ""
    size: int = field(default=0)


# ── ffmpeg helpers ───────────────────────────────────────────────────────────

def ffprobe(path):
    p = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries",
         "stream=codec_name,channels,sample_rate,duration_ts,time_base", "-of", "json", str(path)],
        capture_output=True, text=True)
    try:
        s = json.loads(p.stdout)["streams"][0]
    except (ValueError, KeyError, IndexError):
        raise VerifyError(f"unreadable audio: {path.name}")
    sr = int(s["sample_rate"])
    samples = int(s["duration_ts"]) if s.get("time_base") == f"1/{sr}" and "duration_ts" in s else None
    return {"codec": s["codec_name"], "channels": int(s["channels"]), "rate": sr, "samples": samples}


def run_astats(inputs, graph):
    """Run a filter graph ending in astats; return (peak_db, rms_db, samples) of the output."""
    cmd = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "info"]
    for path in inputs:
        cmd += ["-i", str(path)]
    cmd += ["-filter_complex", graph, "-map", "[o]", "-f", "null", "-"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        last = (p.stderr.strip().splitlines() or ["no output"])[-1]
        raise VerifyError(f"ffmpeg failed: {last}")
    idx = p.stderr.rfind("Overall")
    if idx < 0:
        return None  # nothing flowed through the filter (e.g. an empty tail)
    seg = p.stderr[idx:]

    def val(label):
        m = re.search(label + r": (\S+)", seg)
        return float(m.group(1)) if m else None

    samples = val("Number of samples")
    return val("Peak level dB"), val("RMS level dB"), int(samples) if samples is not None else None


def raw_chain(n_raw):
    # Same join the merge step uses for a pair; a lone odd track stays mono.
    return "[0:a][1:a]join=inputs=2:channel_layout=stereo" if n_raw == 2 else "[0:a]anull"


# ── verification ─────────────────────────────────────────────────────────────

def verify(item, tolerance_db, tail_db, min_gain_db):
    raws = item.raws
    if not item.proc.is_file():
        raise VerifyError("no processed file yet")

    praw = [ffprobe(r) for r in raws]
    pproc = ffprobe(item.proc)
    if pproc["codec"] != "pcm_s24le":
        raise VerifyError(f"processed file is {pproc['codec']}, not 24-bit (rebuild processed/ first)")
    want_ch = 2 if len(raws) == 2 else 1
    if pproc["channels"] != want_ch:
        raise VerifyError(f"processed has {pproc['channels']} channels, expected {want_ch}")
    if any(r["channels"] != 1 for r in praw):
        raise VerifyError("raw track is not mono")
    if any(r["rate"] != pproc["rate"] for r in praw):
        raise VerifyError("sample rate differs between raw and processed")
    if len({r["samples"] for r in praw}) > 1 and len(raws) == 2:
        raise VerifyError("the two raw tracks differ in length")

    # Pass 1: processed audio — its length and RMS.
    stats = run_astats([item.proc], f"[0:a]aformat=sample_fmts=dbl,{ASTATS}[o]")
    if not stats or stats[2] is None:
        raise VerifyError("processed file has no audio")
    _, rms_p, n_proc = stats

    # Pass 2: the same span of raw audio — RMS, to fit the normalize gain.
    chain = raw_chain(len(raws))
    stats = run_astats(raws, f"{chain},aformat=sample_fmts=dbl,atrim=end_sample={n_proc},{ASTATS}[o]")
    if not stats or stats[2] != n_proc:
        raise VerifyError(f"raw audio is shorter than processed ({stats[2] if stats else 0} vs {n_proc} samples)")
    _, rms_r, _ = stats

    if math.isinf(rms_p) and math.isinf(rms_r):
        gain = 1.0  # both silent
    elif math.isinf(rms_p) or math.isinf(rms_r):
        raise VerifyError("silent in one of raw/processed but not the other")
    else:
        gain = 10 ** ((rms_p - rms_r) / 20)

    # The null test below is absolute (dBFS), so a heavily attenuated copy would pass it
    # while having kept fewer of the raw's bits. Normalize boosts quiet tracks (by up to
    # ~60 dB) and only trims a hair off loud ones, so cap how far the fit may attenuate.
    gain_db = 20 * math.log10(gain)
    if gain_db < min_gain_db:
        raise VerifyError(f"processed is {-gain_db:.1f} dB quieter than raw (fitted gain {gain_db:+.1f} dB); "
                          f"normalize never attenuates that much, so detail may have been lost (see --min-gain)")

    # Pass 3: null test. processed - gain*raw must be at the 24-bit noise floor.
    graph = (f"{chain},aformat=sample_fmts=dbl,atrim=end_sample={n_proc},"
             f"volume={gain:.12f}:precision=double[r];"
             f"[{len(raws)}:a]aformat=sample_fmts=dbl,volume=-1:precision=double[p];"
             f"[r][p]amix=inputs=2:normalize=0,{ASTATS}[o]")
    stats = run_astats(raws + [item.proc], graph)
    if not stats or stats[0] is None:
        raise VerifyError("could not measure the null test")
    resid = stats[0]
    if resid > tolerance_db:
        raise VerifyError(f"audio differs from raw (residual {resid:.1f} dBFS > {tolerance_db:g}; gain fit {20 * math.log10(gain):+.2f} dB)")

    # Pass 4: anything cut off the end must have been silence.
    n_raw = praw[0]["samples"]
    tail_note = ""
    if n_raw is None or n_raw > n_proc:
        stats = run_astats(raws, f"{chain},aformat=sample_fmts=dbl,atrim=start_sample={n_proc},{ASTATS}[o]")
        tail_peak = stats[0] if stats and stats[0] is not None else -math.inf
        if stats and stats[2]:
            if tail_peak > tail_db + 0.05:
                raise VerifyError(f"processed is shorter and the cut-off end isn't silent (peak {tail_peak:.1f} dBFS)")
            tail_note = f", {stats[2] / pproc['rate']:.0f}s silent tail trimmed"
    return f"gain {20 * math.log10(gain):+.2f} dB, residual {resid:.0f} dBFS{tail_note}"


# ── discovery ────────────────────────────────────────────────────────────────

def discover(raw_dir, proc_dir, sessions):
    """Mirror sync.sh's pairing: odd track + next even track -> one processed file."""
    items, claimed = [], set()
    for lfile in sorted(raw_dir.rglob("*.wav")):
        if lfile.name.startswith("."):
            continue
        rel_dir = lfile.parent.relative_to(raw_dir)
        if sessions and str(rel_dir) not in sessions:
            continue
        m = TR.match(lfile.name)
        if not m or int(m.group(2)) % 2 == 0:
            continue
        num, width = int(m.group(2)), len(m.group(2))
        rfile = lfile.with_name(f"{m.group(1)}{num + 1:0{width}d}{m.group(3)}")
        if rfile.is_file():
            raws, out = [lfile, rfile], f"{m.group(1)}{m.group(2)}-{num + 1:0{width}d}{m.group(3)}"
        else:
            raws, out = [lfile], lfile.name
        claimed.update(raws)
        items.append(Item(proc=proc_dir / rel_dir / out, raws=raws, session=str(rel_dir),
                          size=sum(r.stat().st_size for r in raws)))
    orphans = [p for p in sorted(raw_dir.rglob("*.wav"))
               if p not in claimed and not p.name.startswith(".")
               and (not sessions or str(p.parent.relative_to(raw_dir)) in sessions)]
    return items, orphans


# ── actions ──────────────────────────────────────────────────────────────────

def exclude_pattern(rel):
    # rsync exclude pattern anchored at the transfer root; escape glob characters.
    return "/" + re.sub(r"([\\*?\[])", r"\\\1", rel.as_posix())


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def clean(verified, raw_dir, mode):
    manifest = raw_dir / MANIFEST
    trash = Path.home() / ".Trash" / f"mixer-sync-raw-{time.strftime('%Y%m%d-%H%M%S')}"
    removed = 0
    # Record first: if we're interrupted, a file listed but not yet removed is harmless,
    # a removed file that isn't listed would be re-copied from the card.
    with open(manifest, "a") as mf:
        mf.write(f"# cleaned {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        for item in verified:
            for raw in item.raws:
                mf.write(exclude_pattern(raw.relative_to(raw_dir)) + "\n")
        mf.flush()
    for item in verified:
        for raw in item.raws:
            if mode == "trash":
                dest = trash / raw.relative_to(raw_dir)
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.move(str(raw), str(dest))
            else:
                raw.unlink()
            removed += 1
    for d in sorted({r.parent for i in verified for r in i.raws}, key=lambda p: -len(p.parts)):
        try:
            d.rmdir()  # only succeeds when empty
        except OSError:
            pass
    return removed, (trash if mode == "trash" else None)


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="Verify processed audio against raw originals, then clean raw.",
                                 epilog="Without --delete/--trash this is a dry run: it verifies and reports only.")
    ap.add_argument("--dest", type=Path, default=Path.home() / "Music" / "Mixer",
                    help="folder containing raw/ and processed/ (default: ~/Music/Mixer)")
    act = ap.add_mutually_exclusive_group()
    act.add_argument("--delete", action="store_true", help="permanently delete verified raw files")
    act.add_argument("--trash", action="store_true", help="move verified raw files to the Trash instead")
    ap.add_argument("--yes", action="store_true", help="don't ask for confirmation")
    ap.add_argument("--session", action="append", default=[], metavar="NAME",
                    help="only consider this session folder (repeatable)")
    ap.add_argument("-j", "--jobs", type=int, default=2, help="files to verify in parallel (default: 2)")
    ap.add_argument("--tolerance", type=float, default=-110.0, metavar="DBFS",
                    help="max allowed null-test residual (default: -110; a clean 24-bit copy is near -138)")
    ap.add_argument("--min-gain", type=float, default=-3.0, metavar="DB",
                    help="most the processed file may be quieter than raw (default: -3; with "
                         "PEAK_TARGET -1, normalize attenuates at most 1 dB). Lower it if you set "
                         "PEAK_TARGET in sync.sh below -3")
    ap.add_argument("--tail-threshold", type=float, default=-50.0, metavar="DBFS",
                    help="trimmed-off audio must be at or below this (default: -50, matches sync.sh)")
    args = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found (brew install ffmpeg)")
    raw_dir, proc_dir = args.dest / "raw", args.dest / "processed"
    if not raw_dir.is_dir() or not proc_dir.is_dir():
        sys.exit(f"Expected {raw_dir} and {proc_dir} to exist")

    items, orphans = discover(raw_dir, proc_dir, set(args.session))
    print(f"Verifying {len(items)} processed file(s) against {sum(len(i.raws) for i in items)} raw track(s)...\n")

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        futures = {pool.submit(verify, i, args.tolerance, args.tail_threshold, args.min_gain): i for i in items}
        for n, fut in enumerate(as_completed(futures), 1):
            item = futures[fut]
            try:
                item.detail, item.status = fut.result(), "verified"
                mark = "\033[1;32m✓\033[0m"
            except VerifyError as e:
                item.detail, item.status = str(e), "keep"
                mark = "\033[1;31m✗\033[0m"
            except Exception as e:  # never let a surprise turn into a deletion
                item.detail, item.status = f"unexpected error: {e}", "keep"
                mark = "\033[1;31m✗\033[0m"
            rel = item.proc.relative_to(proc_dir)
            print(f"{mark} [{n}/{len(items)}] {rel}  {item.detail}", flush=True)

    verified = sorted((i for i in items if i.status == "verified"), key=lambda i: str(i.proc))
    kept = [i for i in items if i.status != "verified"]
    free = sum(i.size for i in verified)

    print()
    for o in orphans:
        print(f"\033[1;33m!\033[0m kept (sync.sh doesn't process it, e.g. an even track with no odd partner): "
              f"{o.relative_to(raw_dir)}")
    print(f"\nVerified: {len(verified)} file(s), {sum(len(i.raws) for i in verified)} raw track(s), {human(free)} can be freed")
    print(f"Kept:     {len(kept)} processed file(s) not verified, {len(orphans)} unprocessed raw track(s)")

    if not (args.delete or args.trash):
        print("\nDry run, nothing changed. Re-run with --delete (or --trash) to clean the verified raw files.")
        return
    if not verified:
        print("\nNothing to clean.")
        return

    verb = "Move to the Trash" if args.trash else "PERMANENTLY DELETE"
    if not args.yes:
        if not sys.stdin.isatty():
            sys.exit("\nRefusing to continue without a terminal; pass --yes to confirm.")
        reply = input(f"\n{verb} {sum(len(i.raws) for i in verified)} raw track(s) ({human(free)})? Type 'yes': ")
        if reply.strip().lower() != "yes":
            sys.exit("Aborted, nothing changed.")

    removed, trash = clean(verified, raw_dir, "trash" if args.trash else "delete")
    where = f" to {trash}" if trash else ""
    print(f"\nRemoved {removed} raw track(s){where}; listed in {raw_dir / MANIFEST} so sync.sh won't re-copy them.")


if __name__ == "__main__":
    main()
