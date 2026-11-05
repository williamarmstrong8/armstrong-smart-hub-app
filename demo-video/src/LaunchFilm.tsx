import React from 'react';
import { AbsoluteFill, Img, interpolate, Sequence, spring, staticFile, useCurrentFrame, useVideoConfig } from 'remotion';
import { BAR, BEAT, COPY, CROSSFADE, END_LENGTH, END_START, PHONE_END, SECTION_STARTS, SECTIONS } from './timeline';
import { C, SPRING } from './theme';
import { CapsLabel, HeadlineType } from './components/HeadlineType';
import { PhoneStage } from './components/PhoneStage';
import { EndCard } from './components/EndCard';
import { Finish } from './components/Backdrop';

/** Where things sit in each frame shape (STYLE_GUIDE.md §4). */
const layout = (vertical: boolean) =>
  vertical
    ? {
        phone: { phoneWidth: 520, cx: 540, cy: 1255, tiltScale: 0.45 },
        column: { left: 90, top: 150, width: 900, height: 470, align: 'center' as const },
        cold: 92, headline: 92, name: 112, icon: 170, caption: 24, endIcon: 190, endName: 110, tagline: 46, capsBottom: 160,
      }
    : {
        phone: { phoneWidth: 410, cx: 1320, cy: 540, tiltScale: 1 },
        column: { left: 170, top: 0, width: 760, height: 1080, align: 'left' as const },
        cold: 100, headline: 100, name: 128, icon: 150, caption: 22, endIcon: 160, endName: 138, tagline: 56, capsBottom: 90,
      };

type Layout = ReturnType<typeof layout>;

/** The words beside the phone: one section's headline, and each shot's caption under it. */
const SectionWords: React.FC<{ index: number; size: number; caption: number; align: 'left' | 'center' }> = ({ index, size, caption, align }) => {
  const frame = useCurrentFrame();
  const s = SECTIONS[index];
  const len = s.duration;
  const caps = s.captions ?? [];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', alignItems: align === 'left' ? 'flex-start' : 'center', gap: 30, width: '100%' }}>
      <HeadlineType text={s.headline ?? ''} size={size} align={align} start={CROSSFADE + 2} accent={s.accent} accentColor={s.color} exitAt={len - CROSSFADE - 8} maxWidth={760} />
      <div style={{ position: 'relative', height: caption * 1.4, width: '100%' }}>
        {caps.map(([from, text], i) => {
          const to = i + 1 < caps.length ? caps[i + 1][0] : len - CROSSFADE;
          const inU = interpolate(frame, [Math.max(from, CROSSFADE) + 6, Math.max(from, CROSSFADE) + 16], [0, 1], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
          const outU = interpolate(frame, [to - 8, to], [1, 0], { extrapolateLeft: 'clamp', extrapolateRight: 'clamp' });
          const u = Math.min(inU, outU);
          return (
            <div key={i} style={{ position: 'absolute', inset: 0, opacity: u, filter: u < 1 ? `blur(${(1 - u) * 6}px)` : undefined }}>
              <CapsLabel text={text} size={caption} align={align} color={s.color === C.focus ? C.soft : s.color} />
            </div>
          );
        })}
      </div>
    </div>
  );
};

/** The cold open's two lines, then the icon and name. */
const OpenWords: React.FC<{ L: Layout }> = ({ L }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const align = L.column.align;
  const icon = spring({ frame: frame - 2 * BAR, fps, config: SPRING.weighted, durationInFrames: 40 });
  return (
    <>
      <Sequence durationInFrames={BAR} layout="none">
        <HeadlineType text={COPY.cold1} size={L.cold} align={align} start={4} exitAt={BAR - 9} maxWidth={760} />
      </Sequence>
      <Sequence from={BAR} durationInFrames={BAR} layout="none">
        <HeadlineType text={COPY.cold2} size={L.cold} align={align} start={2} exitAt={BAR - 9} maxWidth={760} />
      </Sequence>
      <Sequence from={2 * BAR} durationInFrames={BAR} layout="none">
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: align === 'left' ? 'flex-start' : 'center', gap: 28 }}>
          <Img
            src={staticFile('icon.png')}
            style={{
              width: L.icon,
              height: L.icon,
              borderRadius: L.icon * 0.2237,
              opacity: icon,
              scale: String(interpolate(icon, [0, 1], [0.7, 1])),
              filter: icon < 1 ? `blur(${(1 - icon) * 16}px)` : undefined,
              boxShadow: `0 24px 60px rgba(0,0,0,0.6), 0 0 90px ${C.accent}33`,
            }}
          />
          <HeadlineType text={COPY.appName} size={L.name} align={align} start={8} stagger={BEAT / 2} exitAt={BAR - 9} maxWidth={900} />
        </div>
      </Sequence>
    </>
  );
};

export const LaunchFilm: React.FC = () => {
  const { width, height } = useVideoConfig();
  const vertical = height > width;
  const L = layout(vertical);
  const col = L.column;
  const columnStyle: React.CSSProperties = {
    position: 'absolute',
    left: col.left,
    top: col.top,
    width: col.width,
    height: col.height,
    display: 'flex',
    flexDirection: 'column',
    justifyContent: 'center',
    alignItems: col.align === 'left' ? 'flex-start' : 'center',
  };

  return (
    <AbsoluteFill style={{ backgroundColor: C.stage }}>
      <Sequence name="Phone" durationInFrames={PHONE_END}>
        <PhoneStage {...L.phone} />
        <Sequence name="Open words" durationInFrames={SECTION_STARTS.fitness}>
          <div style={columnStyle}>
            <OpenWords L={L} />
          </div>
        </Sequence>
        {SECTIONS.map((s, i) =>
          s.headline ? (
            <Sequence key={s.id} name={`${s.id} words`} from={SECTION_STARTS[s.id]} durationInFrames={s.duration}>
              <div style={columnStyle}>
                <SectionWords index={i} size={L.headline} caption={L.caption} align={col.align} />
              </div>
            </Sequence>
          ) : null,
        )}
      </Sequence>

      <Sequence name="End card" from={END_START} durationInFrames={END_LENGTH}>
        <EndCard iconSize={L.endIcon} nameSize={L.endName} taglineSize={L.tagline} capsSize={24} capsBottom={L.capsBottom} />
      </Sequence>

      <Finish />
    </AbsoluteFill>
  );
};
