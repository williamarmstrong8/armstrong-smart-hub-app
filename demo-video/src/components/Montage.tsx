import React from 'react';
import { AbsoluteFill, Img, interpolate, Sequence, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { Video } from '@remotion/media';
import { BEAT, MONTAGE } from '../timeline';
import { EASE } from '../theme';
import { IPhoneFrame } from './IPhoneFrame';
import { Glow } from './Backdrop';

const Cut: React.FC<{ item: (typeof MONTAGE)[number]; index: number; phoneWidth: number }> = ({ item, index, phoneWidth }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  // A 2 % pop on every cut, settling over 6 frames; alternate sizes give the rhythm a pulse.
  const pop = interpolate(frame, [0, 6], [1.02, 1], { extrapolateRight: 'clamp', easing: EASE.land });
  const base = index % 2 === 0 ? 1 : 0.9;
  const drift = interpolate(frame, [0, BEAT], [0, -10]);
  return (
    <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center' }}>
      <div style={{ scale: String(base * pop), translate: `0 ${drift}px` }}>
        <IPhoneFrame width={phoneWidth}>
          {'still' in item ? (
            <Img src={staticFile(item.still)} style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
          ) : (
            <Video src={staticFile(item.clip)} trimBefore={Math.round(item.at * fps)} muted style={{ width: '100%', height: '100%', objectFit: 'cover' }} />
          )}
        </IPhoneFrame>
      </div>
    </AbsoluteFill>
  );
};

/** Fast rhythmic cuts: one screen per beat, flat (no tilt), under a steady accent glow. */
export const Montage: React.FC<{ phoneWidth: number }> = ({ phoneWidth }) => (
  <AbsoluteFill>
    <Glow color="#75B8FF" alpha={0.7} size={phoneWidth * 3.2} />
    {MONTAGE.map((item, i) => (
      <Sequence key={i} from={i * BEAT} durationInFrames={BEAT} premountFor={20}>
        <Cut item={item} index={i} phoneWidth={phoneWidth} />
      </Sequence>
    ))}
  </AbsoluteFill>
);
