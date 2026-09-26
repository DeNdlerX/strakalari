"""The tray process uses the configured language."""



# -- tray language -----------------------------------------------------------

def test_tray_uses_configured_language(monkeypatch, tmp_path):
    import strakalari.flet_ui.tray as tray_mod
    from strakalari.core import i18n

    monkeypatch.setattr(i18n, "_current_lang", "cs")
    tray_mod._apply_language({"language": "en"})
    try:
        assert i18n.get_language() == "en"
    finally:
        i18n.set_language("cs")
