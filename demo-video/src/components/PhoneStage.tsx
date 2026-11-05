import React from 'react';
import { AbsoluteFill, interpolate, interpolateColors, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Video } from '@remotion/media';
import { HOME_BRIGHTNESS_AT, HOME_LOCK_AT, SECTION_STARTS, SECTIONS, sectionLength } from '../timeline';
import { C, EASE, SPRING } from '../theme';
import { IPhoneFrame } from './IPhoneFrame';
import { Glow } from './Backdrop';

/**
 * The one phone that stays on screen from the first second to the montage. It plays every
 * section's shots back to back (hard cuts inside the screen), pushes in slowly through each
 * section and eases back at the next, turns its tilt between sections on the weighted spring,
 * and sits in a glow that takes each section's color.
 */
export const PhoneStage: React.FC<{ phoneWidth: number; cx: number; cy: number; tiltScale: number }> = ({
  phoneWidth,
  cx,
  cy,
  tiltScale,
}) => {
  const frame = useCurrentFrame();
  const { fps, width, height } = useVideoConfig();

  // Which section is playing, and how far through it.
  let index = 0;
  SECTIONS.forEach((s, i) => { if (SECTION_STARTS[s.id] <= frame) index = i; });
  const section = SECTIONS[index];
  const start = SECTION_STARTS[section.id];
  const len = sectionLength(section);
  const local = frame - start;
  const p = interpolate(local, [0, len], [0, 1], { extrapolateRight: 'clamp', easing: EASE.drift });
  const settle = spring({ frame: local, fps, config: SPRING.weighted, durationInFrames: 30 });

  // Push: 1.00 → 1.04 through each section; at a new section it eases back from where the last one ended.
  const push = interpolate(settle, [0, 1], [index === 0 ? 1 : 1.04, 1]) + 0.04 * p;
  // Tilt: from the last section's resting angle toward this one's, then 60 % of the way to straight.
  const prevTilt = index === 0 ? section.tilt : SECTIONS[index - 1].tilt * 0.4;
  const tilt = interpolate(settle, [0, 1], [prevTilt, section.tilt]) * interpolate(p, [0, 1], [1, 0.4]);

  const rise = spring({ frame, fps, config: SPRING.weighted, durationInFrames: 36 });
  const home = SECTION_STARTS.home;
  const lockPunch =
    interpolate(spring({ frame: frame - (home + HOME_LOCK_AT), fps, config: SPRING.weighted, durationInFrames: 24 }), [0, 1], [0, 0.03]) *
    (section.id === 'home' ? 1 : 0);

  // Glow: blend to each section's color over its first beat; the lights warm it while the brightness glides.
  const keys: [number, string][] = [];
  SECTIONS.forEach((s, i) => {
    const at = SECTION_STARTS[s.id];
    if (i > 0) keys.push([at, SECTIONS[i - 1].color]);
    keys.push([at + (i === 0 ? 0 : 18), s.color]);
    if (s.id === 'home') {
      keys.push([at + HOME_BRIGHTNESS_AT, s.color], [at + HOME_BRIGHTNESS_AT + 30, C.warm]);
      keys.push([at + HOME_LOCK_AT - 30, C.warm], [at + HOME_LOCK_AT, s.color]);
    }
  });
  const glow = interpolateColors(frame, keys.map((k) => k[0]), keys.map((k) => k[1]));

  // Every shot, in order, on one clock.
  let from = 0;
  const shots = SECTIONS.flatMap((s) => s.shots).map((shot, i) => {
    const node = (
      <Sequence key={i} from={from} durationInFrames={shot.duration} premountFor={30}>
        <Video src={staticFile(shot.src)} trimBefore={Math.round(shot.trim * fps)} muted style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
      </Sequence>
    );
    from += shot.duration;
    return node;
  });

  return (
    <AbsoluteFill>
      <Glow color={glow} alpha={rise} size={phoneWidth * 3.2} x={`${(cx / width) * 100}%`} y={`${(cy / height) * 100 + 3}%`} />
      <div
        style={{
          position: 'absolute',
          left: cx - phoneWidth * 0.65,
          top: cy + phoneWidth * 1.08,
          width: phoneWidth * 1.3,
          height: phoneWidth * 0.16,
          borderRadius: '50%',
          background: 'radial-gradient(closest-side, rgba(0,0,0,0.85), rgba(0,0,0,0))',
          opacity: rise * 0.9,
          filter: 'blur(10px)',
        }}
      />
      <div style={{ position: 'absolute', left: cx, top: cy, perspective: 2400 }}>
        <div
          style={{
            translate: `-50% calc(-50% + ${interpolate(rise, [0, 1], [220, 0])}px)`,
            opacity: rise,
            scale: String(push + lockPunch),
            transform: `rotateY(${tilt * tiltScale}deg) rotateX(${Math.abs(tilt) * 0.35 * tiltScale}deg)`,
          }}
        >
          <IPhoneFrame width={phoneWidth}>{shots}</IPhoneFrame>
        </div>
      </div>
    </AbsoluteFill>
  );
};
