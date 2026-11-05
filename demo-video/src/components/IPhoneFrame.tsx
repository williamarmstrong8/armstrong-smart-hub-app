import React from 'react';

/**
 * An iPhone 18 Pro body drawn in CSS: titanium edge, black bezel, side buttons and the
 * screen's continuous corner. The Dynamic Island comes from the footage itself (the
 * Simulator records it), so it sits exactly where iOS draws it.
 *
 * `width` is the body width in px; the height follows the screen's 1206 × 2622 aspect.
 */
export const SCREEN_ASPECT = 2622 / 1206;

export const phoneSize = (width: number) => {
  const edge = width * 0.013;
  const bezel = width * 0.024;
  const screenW = width - 2 * (edge + bezel);
  const screenH = screenW * SCREEN_ASPECT;
  return { edge, bezel, screenW, screenH, height: screenH + 2 * (edge + bezel), radius: width * 0.168 };
};

export const IPhoneFrame: React.FC<{ width: number; children: React.ReactNode; shadow?: boolean }> = ({
  width,
  children,
  shadow = true,
}) => {
  const { edge, bezel, screenW, screenH, height, radius } = phoneSize(width);
  const screenRadius = radius - edge - bezel;
  const button = (side: 'left' | 'right', top: number, h: number) => (
    <div
      style={{
        position: 'absolute',
        [side]: -width * 0.008,
        top: height * top,
        width: width * 0.012,
        height: height * h,
        borderRadius: width * 0.01,
        background: 'linear-gradient(90deg, #5d6066, #b9bcc2 50%, #5d6066)',
      }}
    />
  );
  return (
    <div style={{ position: 'relative', width, height }}>
      {button('left', 0.17, 0.035)}
      {button('left', 0.235, 0.065)}
      {button('left', 0.315, 0.065)}
      {button('right', 0.25, 0.1)}
      {/* Titanium edge */}
      <div
        style={{
          position: 'absolute',
          inset: 0,
          borderRadius: radius,
          background: 'linear-gradient(135deg, #8A8D93 0%, #D9DBDF 22%, #6E7177 48%, #C9CCD1 74%, #75787E 100%)',
          boxShadow: shadow ? '0 60px 120px rgba(0,0,0,0.6), 0 18px 40px rgba(0,0,0,0.45)' : undefined,
        }}
      />
      {/* Inner highlight on the edge */}
      <div
        style={{
          position: 'absolute',
          inset: edge * 0.45,
          borderRadius: radius - edge * 0.45,
          boxShadow: 'inset 0 0 0 1px rgba(255,255,255,0.35)',
        }}
      />
      {/* Bezel */}
      <div style={{ position: 'absolute', inset: edge, borderRadius: radius - edge, background: '#050505' }} />
      {/* Screen */}
      <div
        style={{
          position: 'absolute',
          left: edge + bezel,
          top: edge + bezel,
          width: screenW,
          height: screenH,
          borderRadius: screenRadius,
          overflow: 'hidden',
          background: '#000',
        }}
      >
        {children}
      </div>
    </div>
  );
};
