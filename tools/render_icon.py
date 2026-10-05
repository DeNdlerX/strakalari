import os
from playwright.sync_api import sync_playwright
from PIL import Image

svg_path = os.path.abspath("assets/logo.svg")
with open(svg_path, "r", encoding="utf-8") as f:
    svg_content = f.read()

# Make sure viewBox is preserved and width/height is 1080
html_content = f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  html, body {{
    width: 1080px;
    height: 1080px;
    overflow: hidden;
    background: transparent;
  }}
  svg {{
    width: 1080px !important;
    height: 1080px !important;
    display: block;
  }}
</style>
</head>
<body>
{svg_content}
</body>
</html>
"""

temp_html = os.path.abspath("assets/temp_render.html")
with open(temp_html, "w", encoding="utf-8") as f:
    f.write(html_content)

try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1080, "height": 1080}, device_scale_factor=1)
        page.goto(f"file:///{temp_html.replace(os.sep, '/')}")
        page.wait_for_timeout(500)
        output_png = os.path.abspath("assets/logo-1080.png")
        page.screenshot(path=output_png, omit_background=True)
        browser.close()

    im = Image.open(output_png)
    print(f"Successfully rendered: {output_png} ({im.size}, {im.mode})")
finally:
    if os.path.exists(temp_html):
        os.remove(temp_html)
