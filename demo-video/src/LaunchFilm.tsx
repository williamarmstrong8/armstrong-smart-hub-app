import React from 'react';
import { AbsoluteFill, Sequence, useVideoConfig } from 'remotion';
import { BAR, BEAT, COPY, FITNESS_SHOTS, FOCUS_SHOTS, HOME_BRIGHTNESS_AT, HOME_LOCK_AT, HOME_SHOTS, SECTIONS } from './timeline';
import { C } from './theme';
import { HeadlineType } from './components/HeadlineType';
import { AppIconReveal } from './components/AppIconReveal';
import { FeatureBeat } from './components/FeatureBeat';
import { Montage } from './components/Montage';
import { EndCard } from './components/EndCard';
import { Finish, Glow } from './components/Backdrop';

/** Sizes for each frame shape (STYLE_GUIDE.md §4). */
const layout = (vertical: boolean) =>
  vertical
    ? { cold: 96, headline: 112, name: 132, icon: 300, phone: 560, montagePhone: 600, tagline: 46, caps: 24, capsY: 150, capsBottom: 160, tilt: 0.5 }
    : { cold: 120, headline: 140, name: 168, icon: 260, phone: 390, montagePhone: 390, tagline: 56, caps: 24, capsY: 36, capsBottom: 90, tilt: 1 };

const Centered: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <AbsoluteFill style={{ justifyContent: 'center', alignItems: 'center', padding: 80 }}>{children}</AbsoluteFill>
);

/** A one-bar headline card: words land on 8ths, leave on the last beat. */
const Title: React.FC<{ text: string; size: number; glow?: string; accent?: string; accentColor?: string }> = ({
  text,
  size,
  glow,
  accent,
  accentColor,
}) => (
  <AbsoluteFill>
    {glow ? <Glow color={glow} alpha={0.55} y="80%" size={1400} /> : null}
    <Centered>
      <HeadlineType text={text} size={size} start={2} accent={accent} accentColor={accentColor} exitAt={BAR - 10} />
    </Centered>
  </AbsoluteFill>
);

export const LaunchFilm: React.FC = () => {
  const { width, height } = useVideoConfig();
  const vertical = height > width;
  const L = layout(vertical);
  const tilt = (dir: -1 | 1) => (vertical ? 0 : dir);

  return (
    <AbsoluteFill style={{ backgroundColor: C.stage }}>
      {/* 1–2 · Cold open */}
      <Sequence name="Cold open" from={SECTIONS.coldOpen.from} durationInFrames={SECTIONS.coldOpen.duration}>
        <Sequence name="Five apps" durationInFrames={BAR}>
          <Centered>
            <HeadlineType text={COPY.cold1} size={L.cold} start={4} exitAt={BAR - 10} />
          </Centered>
        </Sequence>
        <Sequence name="So I built one" from={BAR} durationInFrames={BAR}>
          <Glow color={C.accent} alpha={0.45} size={1200} />
          <Centered>
            <HeadlineType text={COPY.cold2} size={L.cold} start={2} stagger={BEAT / 2} />
          </Centered>
        </Sequence>
      </Sequence>

      {/* 3–4 · Icon and name */}
      <Sequence name="Reveal" from={SECTIONS.reveal.from} durationInFrames={SECTIONS.reveal.duration}>
        <AppIconReveal iconSize={L.icon} nameSize={L.name} />
      </Sequence>

      {/* 5–8 · Fitness */}
      <Sequence name="Fitness title" from={SECTIONS.fitnessTitle.from} durationInFrames={SECTIONS.fitnessTitle.duration}>
        <Title text={COPY.fitness} size={L.headline} glow={C.fitness} />
      </Sequence>
      <Sequence name="Fitness phone" from={SECTIONS.fitness.from} durationInFrames={SECTIONS.fitness.duration}>
        <FeatureBeat
          shots={FITNESS_SHOTS}
          phoneWidth={L.phone}
          tilt={tilt(-1)}
          glow={[[0, C.fitness]]}
          caps={{ text: COPY.fitnessCaps, from: 24, size: L.caps, y: L.capsY }}
        />
      </Sequence>

      {/* 9–11 · Home */}
      <Sequence name="Home title" from={SECTIONS.homeTitle.from} durationInFrames={SECTIONS.homeTitle.duration}>
        <Title text={COPY.home} size={L.headline} glow={C.accent} accent={COPY.homeAccent} accentColor={C.accent} />
      </Sequence>
      <Sequence name="Home phone" from={SECTIONS.home.from} durationInFrames={SECTIONS.home.duration}>
        <FeatureBeat
          shots={HOME_SHOTS}
          phoneWidth={L.phone}
          tilt={tilt(1)}
          glow={[
            [0, C.accent],
            [HOME_BRIGHTNESS_AT, C.accent],
            [HOME_BRIGHTNESS_AT + 30, C.warm],
            [HOME_LOCK_AT - 40, C.warm],
            [HOME_LOCK_AT - 10, C.accent],
          ]}
          caps={{ text: COPY.homeCaps, from: 3 * BAR + 6, size: L.caps, y: L.capsY }}
          punch={[HOME_LOCK_AT, 0.04]}
        />
      </Sequence>

      {/* 12–13 · Focus */}
      <Sequence name="Focus title" from={SECTIONS.focusTitle.from} durationInFrames={SECTIONS.focusTitle.duration}>
        <Title text={COPY.focus} size={L.headline} glow={C.focus} />
      </Sequence>
      <Sequence name="Focus phone" from={SECTIONS.focus.from} durationInFrames={SECTIONS.focus.duration}>
        <FeatureBeat shots={FOCUS_SHOTS} phoneWidth={L.phone} tilt={0} glow={[[0, C.focus]]} />
      </Sequence>

      {/* 14 · Montage */}
      <Sequence name="Montage" from={SECTIONS.montage.from} durationInFrames={SECTIONS.montage.duration}>
        <Montage phoneWidth={L.montagePhone} />
      </Sequence>

      {/* 15 · End card */}
      <Sequence name="End card" from={SECTIONS.endCard.from} durationInFrames={SECTIONS.endCard.duration}>
        <EndCard
          iconSize={L.icon * 0.62}
          nameSize={L.name * 0.82}
          taglineSize={L.tagline}
          capsSize={L.caps}
          capsBottom={L.capsBottom}
        />
      </Sequence>

      <Finish />
    </AbsoluteFill>
  );
};
