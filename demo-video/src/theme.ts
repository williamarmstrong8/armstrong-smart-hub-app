import { Easing } from 'remotion';
import { loadFont } from '@remotion/google-fonts/Inter';

/** Inter (SIL Open Font License), the film's typeface. */
export const { fontFamily } = loadFont('normal', { weights: ['400', '500', '600'], subsets: ['latin'] });

/** Colors from the app's own tokens (HubDesign dark + Fitness palette). See STYLE_GUIDE.md. */
export const C = {
  stage: '#000000',
  ink: '#F3EFED',
  soft: '#B8B0AB',
  accent: '#75B8FF', // HubDesign.action (dark)
  fitness: '#3DDC6E', // Fit.readiness (dark)
  sleep: '#8B6CFF',
  warm: '#FF990A', // Fit.activity: the lights' glow
  focus: '#F3EFED',
};

/** Easing from STYLE_GUIDE.md. */
export const EASE = {
  /** Word landing: blur 16 px → 0, rise 36 px → 0 over 9 frames. */
  land: Easing.bezier(0.22, 1, 0.36, 1),
  /** Leaving: ease-in. */
  exit: Easing.bezier(0.55, 0, 1, 0.45),
  /** Gentle in-out for drifts. */
  drift: Easing.bezier(0.45, 0, 0.55, 1),
};

/** Springs: `weighted` is the apple-wow tutorial's `damping: 200` (no bounce). */
export const SPRING = {
  weighted: { damping: 200 },
  glide: { stiffness: 150, damping: 20, mass: 1 },
};
