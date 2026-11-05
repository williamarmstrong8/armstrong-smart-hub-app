// Renders review stills at the given frames, bundling once: node scripts/stills.mjs <comp> <outdir> <frame...>
import { bundle } from '@remotion/bundler';
import { renderStill, selectComposition } from '@remotion/renderer';
import path from 'node:path';

const [comp, outDir, ...frames] = process.argv.slice(2);
const serveUrl = await bundle({ entryPoint: path.resolve('src/index.ts') });
const composition = await selectComposition({ serveUrl, id: comp });
for (const f of frames) {
  const frame = Number(f);
  await renderStill({ serveUrl, composition, frame, output: path.join(outDir, `${comp}-${String(frame).padStart(4, '0')}.jpeg`), imageFormat: 'jpeg', jpegQuality: 85, scale: 0.5 });
  console.log('still', frame);
}
