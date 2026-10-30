#!/usr/bin/env python3
"""Deterministic design contracts; no iOS SDK or third-party dependencies required.

Checks source tokens, text contrast, shared page adoption and known jank patterns.
This is not a replacement for SwiftUI type checking or on-device rendering tests.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Armstrong-Smart-Hub-App"


def source(path):
    return (APP / path).read_text()


def luminance(hex_value):
    channels = [(hex_value >> shift & 255) / 255 for shift in (16, 8, 0)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return sum(c * w for c, w in zip(linear, (0.2126, 0.7152, 0.0722)))


class DesignSystemChecks(unittest.TestCase):
    def test_normal_text_contrast_in_both_appearances(self):
        tokens = {
            name: (int(light, 16), int(dark, 16))
            for name, light, dark in re.findall(
                r"static let (\w+) = adaptive\(0x([0-9A-F]{6}), 0x([0-9A-F]{6})\)",
                source("Shared/DesignSystem.swift"),
            )
        }
        for foreground in ("ink", "secondary", "action", "positive", "warning", "danger"):
            for background in ("page", "surface", "raised", "track"):
                for appearance in (0, 1):
                    with self.subTest(foreground=foreground, background=background, appearance=appearance):
                        a = luminance(tokens[foreground][appearance])
                        b = luminance(tokens[background][appearance])
                        self.assertGreaterEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5)

    def test_main_content_tabs_use_one_page_container(self):
        for path in ("Home/HomeView.swift", "Finance/FinanceView.swift", "Calendar/CalendarView.swift"):
            with self.subTest(path=path):
                text = source("Features/" + path)
                self.assertIn("HubTabPage(", text)
                self.assertNotIn("topBar.padding(.bottom, -", text)

    def test_feature_surfaces_alias_shared_tokens(self):
        for path in ("Brick/BrickDesign.swift", "Fitness/FitnessDesign.swift"):
            self.assertIn("static let page = HubDesign.page", source("Features/" + path))
        self.assertIn("reduceMotion ? nil : standard", source("Shared/DesignSystem.swift"))
        self.assertIn("minHitTarget: CGFloat = 44", source("Shared/DesignSystem.swift"))

    def test_removed_scroll_and_presentation_hazards(self):
        root = source("App/HubApp.swift")
        self.assertNotIn(".blur(radius:", root)
        self.assertNotIn(".animation(", root)
        for path in ("Brick/BrickView.swift", "Fitness/FitnessView.swift"):
            self.assertNotIn(".padding(.top, -600)", source("Features/" + path))
        media = source("Features/Home/MediaViews.swift")
        self.assertNotIn('value(forKey: "_displayCornerRadius")', media)
        self.assertIn("kCGImageSourceThumbnailMaxPixelSize", media)
        self.assertIn('"/t/p/w780/"', media)


if __name__ == "__main__":
    unittest.main(verbosity=2)
