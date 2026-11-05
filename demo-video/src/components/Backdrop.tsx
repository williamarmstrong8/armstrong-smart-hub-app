import React from 'react';
import { AbsoluteFill, useCurrentFrame } from 'remotion';

/** A soft radial glow in a data color, behind the subject. Alpha 0–1 scales the color's 18 % peak. */
export const Glow: React.FC<{ color: string; alpha?: number; x?: string; y?: string; size?: number }> = ({
  color,
  alpha = 1,
  x = '50%',
  y = '52%',
  size = 1100,
}) => {
  const a = Math.round(Math.max(0, Math.min(1, alpha)) * 0.18 * 255)
    .toString(16)
    .padStart(2, '0');
  return (
    <AbsoluteFill
      style={{
        background: `radial-gradient(${size}px ${size * 0.8}px at ${x} ${y}, ${color}${a} 0%, ${color}00 60%)`,
      }}
    />
  );
};

/** Vignette and a 3 % film grain. The grain's seed is the frame, so every render matches. */
export const Finish: React.FC = () => {
  const frame = useCurrentFrame();
  return (
    <>
      <AbsoluteFill
        style={{ background: 'radial-gradient(ellipse at 50% 50%, rgba(0,0,0,0) 55%, rgba(0,0,0,0.55) 100%)' }}
      />
      <AbsoluteFill style={{ opacity: 0.035, mixBlendMode: 'overlay' }}>
        <svg width="100%" height="100%" xmlns="http://www.w3.org/2000/svg">
          <filter id={`grain-${frame}`}>
            <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed={frame % 97} stitchTiles="stitch" />
            <feColorMatrix type="saturate" values="0" />
          </filter>
          <rect width="100%" height="100%" filter={`url(#grain-${frame})`} />
        </svg>
      </AbsoluteFill>
    </>
  );
};
