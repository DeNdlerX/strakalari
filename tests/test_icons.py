"""Branding assets: sources render, distribution sizes exist, helpers resolve."""

from pathlib import Path

from PIL import Image

from strakalari.flet_ui.assets import assets_dir, tray_icon_path, window_icon_path

REPO = Path(__file__).resolve().parent.parent
ASSETS = REPO / "assets"


class TestAssetSources:
    def test_svg_masters_exist(self):
        assert (ASSETS / "logo.svg").is_file()
        assert (ASSETS / "tray-icon.svg").is_file()

    def test_logo_svg_namespaces_and_layers(self):
        text = (ASSETS / "logo.svg").read_text(encoding="utf-8")
        assert 'xmlns="http://www.w3.org/2000/svg"' in text
        for layer in ('id="hexagon"', 'id="symbols"', 'id="ink-effect"'):
            assert layer in text

    def test_tray_svg_is_flat_monochrome(self):
        text = (ASSETS / "tray-icon.svg").read_text(encoding="utf-8")
        assert "feDropShadow" not in text
        assert "linearGradient" not in text
        assert "ink-effect" not in text


class TestDistributionSizes:
    def test_hicolor_logo_set(self):
        for size in (16, 22, 24, 32, 36, 48, 64, 72, 96, 128, 192, 256, 512):
            img = Image.open(ASSETS / f"logo-{size}.png")
            assert img.size == (size, size), f"logo-{size}.png"

    def test_tray_png_set(self):
        for name, size in (("tray-icon.png", 64), ("tray-icon-16.png", 16),
                           ("tray-icon-22.png", 22), ("tray-icon-24.png", 24),
                           ("tray-icon-32.png", 32), ("tray-icon-48.png", 48)):
            img = Image.open(ASSETS / name)
            assert img.size == (size, size), name

    def test_rasters_have_transparency(self):
        for name in ("logo-256.png", "tray-icon.png", "icon.png", "favicon.png"):
            img = Image.open(ASSETS / name)
            assert "A" in img.getbands(), name
            assert img.getchannel("A").getextrema()[0] == 0, name

    def test_windows_ico_multisize(self):
        ico = Image.open(ASSETS / "icon.ico")
        assert {(16, 16), (32, 32), (48, 48), (256, 256)} <= set(ico.info["sizes"])
        tray = Image.open(ASSETS / "tray-icon.ico")
        assert {(16, 16), (32, 32)} <= set(tray.info["sizes"])

    def test_macos_icns_exists(self):
        icns = Image.open(ASSETS / "icon.icns")
        assert max(icns.info["sizes"])[0] >= 512

    def test_web_icons(self):
        assert Image.open(ASSETS / "favicon.png").size == (32, 32)
        assert Image.open(ASSETS / "android-chrome-192.png").size == (192, 192)
        assert Image.open(ASSETS / "android-chrome-512.png").size == (512, 512)


class TestAssetHelpers:
    def test_assets_dir_resolves_to_repo(self):
        assert assets_dir() == ASSETS

    def test_window_icon_prefers_platform_file(self):
        assert Path(window_icon_path()).is_file()

    def test_tray_icon_is_mono_variant(self):
        path = Path(tray_icon_path())
        assert path.is_file()
        assert path.name.startswith("tray-icon")

    def test_tray_loader_uses_bundled_glyph(self):
        from strakalari.flet_ui.tray import _icon_image

        img = _icon_image()
        assert img is not None
        assert img.size == (64, 64)
