import React from 'react';
import { AbsoluteFill, interpolate, interpolateColors, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Video } from '@remotion/media';
import type { Shot } from '../timeline';
import { EASE, SPRING } from '../theme';
import { IPhoneFrame } from './IPhoneFrame';
import { Glow } from './Backdrop';
import { CapsLabel } from './HeadlineType';

/**
 * A floating iPhone playing a run of shots back to back (hard cuts inside the screen),
 * with a slow push-in, a 3D tilt that eases toward straight, a glow in the feature's
 * color, and an optional caps label. The phone rises in on the weighted spring.
 */
export const FeatureBeat: React.FC<{
  shots: Shot[];
  phoneWidth: number;
  /** -1 tilts the phone toward the left, +1 toward the right, 0 keeps it dead straight. */
  tilt: -1 | 0 | 1;
  /** Glow color keyframes: [frame, hex]. One entry for a steady color. */
  glow: [number, string][];
  caps?: { text: string; from: number; size: number; y: number };
  /** Extra push keyed to a moment, e.g. the door locking: [frame, extra scale]. */
  punch?: [number, number];
  phoneY?: number;
}> = ({ shots, phoneWidth, tilt, glow, caps, punch, phoneY = 0 }) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const total = shots.reduce((n, s) => n + s.duration, 0);

  const rise = spring({ frame, fps, config: SPRING.weighted, durationInFrames: 45 });
  const p = interpolate(frame, [0, total], [0, 1], { extrapolateRight: 'clamp', easing: EASE.drift });
  const push = interpolate(p, [0, 1], [1, 1.06]);
  const extra = punch
    ? interpolate(spring({ frame: frame - punch[0], fps, config: SPRING.weighted, durationInFrames: 30 }), [0, 1], [0, punch[1]])
    : 0;
  const rotY = tilt * interpolate(p, [0, 1], [14, 6]);
  const rotX = tilt === 0 ? 0 : interpolate(p, [0, 1], [6, 2]);
  const glowColor =
    glow.length === 1
      ? glow[0][1]
      : interpolateColors(frame, glow.map((g) => g[0]), glow.map((g) => g[1]));

  let from = 0;
  return (
    <AbsoluteFill>
      <Glow color={glowColor} alpha={rise} size={phoneWidth * 3.2} y="55%" />
      {/* Floor shadow so the phone sits in space */}
      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
        <div
          style={{
            translate: `0 ${phoneWidth * 1.18 + phoneY}px`,
            width: phoneWidth * 1.3,
            height: phoneWidth * 0.16,
            borderRadius: '50%',
            background: 'radial-gradient(closest-side, rgba(0,0,0,0.85), rgba(0,0,0,0))',
            opacity: rise * 0.9,
            filter: 'blur(10px)',
          }}
        />
      </AbsoluteFill>
      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', perspective: 2400 }}>
        <div
          style={{
            translate: `0 ${interpolate(rise, [0, 1], [260, 0]) + phoneY}px`,
            opacity: rise,
            scale: String(push + extra),
            transform: `rotateY(${rotY}deg) rotateX(${rotX}deg)`,
            transformStyle: 'preserve-3d',
          }}
        >
          <IPhoneFrame width={phoneWidth}>
            {shots.map((s, i) => {
              const seq = (
                <Sequence key={i} from={from} durationInFrames={s.duration} premountFor={30}>
                  <Video
                    src={staticFile(s.src)}
                    trimBefore={Math.round(s.trim * fps)}
                    muted
                    style={{ width: '100%', height: '100%', objectFit: 'cover' }}
                  />
                </Sequence>
              );
              from += s.duration;
              return seq;
            })}
          </IPhoneFrame>
        </div>
      </AbsoluteFill>
      {caps ? (
        <AbsoluteFill style={{ alignItems: 'center', top: caps.y }}>
          <CapsLabel
            text={caps.text}
            size={caps.size}
            opacity={interpolate(frame, [caps.from, caps.from + 12, durationInFrames - 8, durationInFrames], [0, 1, 1, 0], {
              extrapolateLeft: 'clamp',
              extrapolateRight: 'clamp',
            })}
          />
        </AbsoluteFill>
      ) : null}
    </AbsoluteFill>
  );
};
