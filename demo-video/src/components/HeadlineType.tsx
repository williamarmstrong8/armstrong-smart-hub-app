import React from 'react';
import { interpolate, useCurrentFrame } from 'remotion';
import { BEAT } from '../timeline';
import { C, EASE, fontFamily } from '../theme';

/**
 * Big, tight headline that builds word by word on the beat grid. Every word keeps its
 * slot from the first frame (invisible until it lands), so the line never re-centers.
 * Words land on eighth notes: blur 16 → 0 px and rise 36 → 0 px over 9 frames.
 */
export const HeadlineType: React.FC<{
  text: string;
  size: number;
  /** Frame (within the parent sequence) the first word lands. */
  start?: number;
  /** Frames between words: half a beat by default. */
  stagger?: number;
  /** Words to tint in `accentColor` (an exact substring of `text`). */
  accent?: string;
  accentColor?: string;
  color?: string;
  weight?: number;
  /** Frame the whole line starts leaving (blur out), or undefined to stay. */
  exitAt?: number;
  maxWidth?: number;
  tracking?: string;
  align?: 'left' | 'center';
}> = ({
  text,
  size,
  start = 0,
  stagger = BEAT / 2,
  accent,
  accentColor = C.accent,
  color = C.ink,
  weight = 600,
  exitAt,
  maxWidth = 1600,
  tracking,
  align = 'center',
}) => {
  const frame = useCurrentFrame();
  const words = text.split(' ');
  const accentWords = new Set(accent ? accent.split(' ').map((w) => w) : []);
  const accentStart = accent ? text.indexOf(accent) : -1;
  let cursor = 0;

  const leave = exitAt === undefined ? 0 : interpolate(frame, [exitAt, exitAt + 8], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: EASE.exit,
  });

  return (
    <div
      style={{
        fontFamily,
        fontSize: size,
        fontWeight: weight,
        lineHeight: 1.04,
        letterSpacing: tracking ?? (size >= 140 ? '-0.035em' : '-0.02em'),
        color,
        textAlign: align,
        maxWidth,
        opacity: 1 - leave,
        filter: leave > 0 ? `blur(${leave * 12}px)` : undefined,
        translate: `0 ${-leave * 16}px`,
      }}
    >
      {words.map((word, i) => {
        const at = cursor;
        cursor += word.length + 1;
        const isAccent = accentStart >= 0 && at >= accentStart && at < accentStart + (accent?.length ?? 0) && accentWords.size > 0;
        const u = interpolate(frame, [start + i * stagger, start + i * stagger + 9], [0, 1], {
          extrapolateLeft: 'clamp',
          extrapolateRight: 'clamp',
          easing: EASE.land,
        });
        return (
          <React.Fragment key={i}>
            <span
              style={{
                display: 'inline-block',
                opacity: u,
                translate: `0 ${(1 - u) * 36}px`,
                filter: u < 1 ? `blur(${(1 - u) * 16}px)` : undefined,
                color: isAccent ? accentColor : undefined,
              }}
            >
              {word}
            </span>
            {i < words.length - 1 ? ' ' : null}
          </React.Fragment>
        );
      })}
    </div>
  );
};

/** Small caps label: restrained, wide tracking, secondary ink. */
export const CapsLabel: React.FC<{ text: string; size?: number; opacity?: number; color?: string; align?: 'left' | 'center' }> = ({
  text,
  size = 24,
  opacity = 1,
  color = C.soft,
  align = 'center',
}) => (
  <div
    style={{
      fontFamily,
      fontSize: size,
      fontWeight: 500,
      letterSpacing: '0.16em',
      color,
      opacity,
      textAlign: align,
    }}
  >
    {text}
  </div>
);
