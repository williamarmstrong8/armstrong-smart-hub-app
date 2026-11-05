import React from 'react';
import { AbsoluteFill, Img, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { BEAT, COPY } from '../timeline';
import { C, EASE, SPRING } from '../theme';
import { CapsLabel, HeadlineType } from './HeadlineType';
import { Glow } from './Backdrop';

/** Icon, name, tagline and the small-caps line. Everything drifts up 8 px; the last 15 frames fade to black. */
export const EndCard: React.FC<{ iconSize: number; nameSize: number; taglineSize: number; capsSize: number; capsBottom: number }> = ({
  iconSize,
  nameSize,
  taglineSize,
  capsSize,
  capsBottom,
}) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const icon = spring({ frame, fps, config: SPRING.weighted, durationInFrames: 40 });
  const drift = interpolate(frame, [0, durationInFrames], [0, -8], { easing: EASE.drift });
  const fade = interpolate(frame, [durationInFrames - 15, durationInFrames], [1, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const glow = interpolate(frame, [0, 20, durationInFrames - 72, durationInFrames], [0, 0.7, 0.7, 0], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const caps = interpolate(frame, [4 * BEAT, 4 * BEAT + 14], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });

  return (
    <AbsoluteFill style={{ opacity: fade }}>
      <Glow color={C.accent} alpha={glow} size={iconSize * 4} y="44%" />
      <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', translate: `0 ${drift}px` }}>
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: nameSize * 0.32 }}>
          <Img
            src={staticFile('icon.png')}
            style={{
              width: iconSize,
              height: iconSize,
              borderRadius: iconSize * 0.2237,
              opacity: icon,
              scale: String(interpolate(icon, [0, 1], [0.85, 1])),
              filter: icon < 1 ? `blur(${(1 - icon) * 12}px)` : undefined,
              boxShadow: '0 24px 60px rgba(0,0,0,0.6)',
            }}
          />
          <HeadlineType text={COPY.appName} size={nameSize} start={6} stagger={BEAT / 2} />
          <div style={{ marginTop: -nameSize * 0.12 }}>
            <HeadlineType text={COPY.tagline} size={taglineSize} weight={500} color={C.soft} start={2 * BEAT} stagger={BEAT / 2} />
          </div>
        </div>
      </AbsoluteFill>
      <AbsoluteFill style={{ justifyContent: 'flex-end', alignItems: 'center', paddingBottom: capsBottom }}>
        <CapsLabel text={COPY.endCaps} size={capsSize} opacity={caps} />
      </AbsoluteFill>
    </AbsoluteFill>
  );
};
