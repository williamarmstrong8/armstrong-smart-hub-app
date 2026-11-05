#!/usr/bin/env python3
"""Shortens a recording's still stretches to `hold` seconds, keeping every moving frame.
   tighten.py <in.mp4> <out.mp4> [hold=0.55] [lead=0.4]
   `lead` is how much of the first still (the app sitting before anything happens) to keep.
   Prints a map of where source seconds land in the output, for timeline.ts."""
import re, subprocess, sys
src, out = sys.argv[1], sys.argv[2]
hold = float(sys.argv[3]) if len(sys.argv) > 3 else 0.55
lead = float(sys.argv[4]) if len(sys.argv) > 4 else 0.4
dur = float(subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', src]))
log = subprocess.run(['ffmpeg', '-i', src, '-vf', 'freezedetect=n=0.002:d=0.3', '-map', '0:v', '-f', 'null', '-'],
                     capture_output=True, text=True).stderr
starts = [float(x) for x in re.findall(r'freeze_start: ([\d.]+)', log)]
ends = [float(x) for x in re.findall(r'freeze_end: ([\d.]+)', log)] + [dur]
keep, t = [], 0.0
for i, (a, b) in enumerate(zip(starts, ends)):
    h = lead if i == 0 and a < 0.05 else hold
    if b - a > h:
        keep.append((t, a + h))
        t = b
keep.append((t, dur))
expr = '+'.join(f'between(t,{a:.3f},{b:.3f})' for a, b in keep if b > a)
subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', src, '-vf', f"select='{expr}',setpts=N/30/TB", '-r', '30',
                '-c:v', 'libx264', '-crf', '16', '-preset', 'slow', '-pix_fmt', 'yuv420p', '-an', out], check=True)
pos = 0.0
for a, b in keep:
    if b > a:
        print(f'  src {a:5.1f}–{b:5.1f}  → out {pos:5.1f}')
        pos += b - a
print(f'{out}: {dur:.1f} s → {pos:.1f} s')
