import React from 'react';
import { AbsoluteFill, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { BAR, BEAT, COPY } from '../timeline';
import { C, SPRING } from '../theme';
import { HeadlineType } from './HeadlineType';
import { Glow } from './Backdrop';

/**
 * Apple-wow's time remap: the first 20 frames run at 1.5×, the rest at 0.5×, so the
 * icon bursts in and then floats. Integrates the speed curve up to `frame`.
 */
const remap = (frame: number) => {
  let t = 0;
  for (let i = 0; i <= frame; i++) t += i < 20 ? 1.5 : 0.5;
  return t;
};

/** Two bars: the icon materializes (bar 1), then rises into a lockup with the app name (bar 2). */
export const AppIconReveal: React.FC<{ iconSize: number; nameSize: number }> = ({ iconSize, nameSize }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = remap(frame);
  const appear = spring({ frame: t, fps, config: SPRING.weighted, durationInFrames: 60 });
  const lift = spring({ frame: frame - BAR, fps, config: SPRING.weighted, durationInFrames: 40 });
  const leave = interpolate(frame, [2 * BAR - 10, 2 * BAR], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
  const push = interpolate(frame, [0, 2 * BAR], [1, 1.04]);

  const scale = interpolate(appear, [0, 1], [0.6, 1]) * interpolate(lift, [0, 1], [1, 0.62]);
  const y = interpolate(lift, [0, 1], [0, -nameSize * 0.95]);
  const radius = iconSize * 0.2237; // iOS icon squircle approximation

  return (
    <AbsoluteFill style={{ scale: String(push), opacity: 1 - leave, filter: leave ? `blur(${leave * 10}px)` : undefined }}>
      <Glow color={C.accent} alpha={appear * 0.8} size={iconSize * 3.2} y="48%" />
      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
        <div style={{ position: 'relative', translate: `0 ${y}px`, scale: String(scale) }}>
          {/* Echo rings: four copies, 3 frames apart, scaled out and fading (apple-wow Trail). */}
          {[1, 2, 3, 4].map((i) => {
            const p = spring({ frame: remap(Math.max(0, frame - i * 3)), fps, config: SPRING.weighted, durationInFrames: 70 });
            return (
              <div
                key={i}
                style={{
                  position: 'absolute',
                  inset: 0,
                  borderRadius: radius,
                  border: `2px solid ${C.ink}`,
                  opacity: (0.1 - i * 0.02) * (1 - p) * appear * 3,
                  scale: String(1 + p * (0.25 + i * 0.12)),
                }}
              />
            );
          })}
          <Img
            src={staticFile('icon.png')}
            style={{
              width: iconSize,
              height: iconSize,
              borderRadius: radius,
              display: 'block',
              opacity: appear,
              filter: appear < 1 ? `blur(${(1 - appear) * 18}px)` : undefined,
              boxShadow: `0 30px 80px rgba(0,0,0,0.6), 0 0 120px ${C.accent}22`,
            }}
          />
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', translate: `0 ${iconSize * 0.42}px` }}>
        <HeadlineType text={COPY.appName} size={nameSize} start={BAR + 6} stagger={BEAT} />
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
