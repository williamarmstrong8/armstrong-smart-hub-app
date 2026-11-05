import React from 'react';
import { Composition } from 'remotion';
import { LaunchFilm } from './LaunchFilm';
import { DURATION, FPS } from './timeline';

export const RemotionRoot: React.FC = () => (
  <>
    <Composition id="LaunchFilm" component={LaunchFilm} durationInFrames={DURATION} fps={FPS} width={1920} height={1080} />
    <Composition id="LaunchFilmVertical" component={LaunchFilm} durationInFrames={DURATION} fps={FPS} width={1080} height={1920} />
  </>
);
