#!/usr/bin/env python3
"""
Script pour générer l'icône de l'application ShareManager.
Dessine l'icône "partager" classique d'iOS (carré ouvert + flèche vers le haut)
sur un fond bleu en dégradé, avec une ombre portée, et une forme dont la
hauteur a été réduite de 10%.

Nécessite: pip install pillow
"""

import math

from PIL import Image, ImageDraw, ImageFilter


SIZE = 1024
SCALE = 4       # super-sampling pour lisser les bords
VSCALE = 0.9    # compression verticale du dessin (hauteur -10%)


def draw_share_icon(draw: ImageDraw.ImageDraw, size: int) -> None:
    """Dessine le glyphe de partage, centré, sur une image de côté `size`.
    La hauteur du dessin est compressée autour du centre via VSCALE."""

    white = (255, 255, 255, 255)
    stroke = int(size * 0.065)
    cx = size / 2
    cy = size / 2

    def sy(fraction: float) -> float:
        """Échelle verticale autour du centre."""
        y = fraction * size
        return cy + (y - cy) * VSCALE

    # --- Boîte (carré ouvert vers le haut) ---
    box_width = size * 0.50
    box_left = cx - box_width / 2
    box_right = cx + box_width / 2
    box_top = sy(0.50)
    box_bottom = sy(0.86)

    # Côté gauche
    draw.rounded_rectangle(
        [box_left - stroke / 2, box_top,
         box_left + stroke / 2, box_bottom + stroke / 2],
        radius=stroke / 2,
        fill=white,
    )
    # Côté droit
    draw.rounded_rectangle(
        [box_right - stroke / 2, box_top,
         box_right + stroke / 2, box_bottom + stroke / 2],
        radius=stroke / 2,
        fill=white,
    )
    # Côté bas
    draw.rounded_rectangle(
        [box_left - stroke / 2, box_bottom - stroke / 2,
         box_right + stroke / 2, box_bottom + stroke / 2],
        radius=stroke / 2,
        fill=white,
    )
    # Pastilles pour adoucir les coins inférieurs
    draw.ellipse(
        [box_left - stroke / 2, box_bottom - stroke / 2,
         box_left + stroke / 2, box_bottom + stroke / 2],
        fill=white,
    )
    draw.ellipse(
        [box_right - stroke / 2, box_bottom - stroke / 2,
         box_right + stroke / 2, box_bottom + stroke / 2],
        fill=white,
    )

    # --- Flèche verticale vers le haut ---
    arrow_tip_y = sy(0.10)
    arrow_bottom = sy(0.66)
    shaft_half = stroke / 2

    # Pointe en chevron épais (polygone), hauteur compressée par VSCALE
    head_half_width = size * 0.14
    head_height = size * 0.17 * VSCALE
    t = stroke

    dx = head_half_width
    dy = head_height
    L = math.sqrt(dx * dx + dy * dy)
    off_x = t * dy / L
    off_y = t * dx / L
    s = off_y / dy

    outer_tip = (cx, arrow_tip_y)
    outer_bl = (cx - dx, arrow_tip_y + dy)
    outer_br = (cx + dx, arrow_tip_y + dy)
    inner_tip_y = arrow_tip_y + t * L / dx
    inner_tip = (cx, inner_tip_y)
    inner_bl = (outer_bl[0] + off_x + s * dx, outer_bl[1])
    inner_br = (outer_br[0] - off_x - s * dx, outer_br[1])

    draw.polygon(
        [outer_tip, outer_br, inner_br, inner_tip, inner_bl, outer_bl],
        fill=white,
    )

    # Tige, du dessous du chevron jusque dans la boîte
    draw.rounded_rectangle(
        [cx - shaft_half, inner_tip_y,
         cx + shaft_half, arrow_bottom],
        radius=shaft_half,
        fill=white,
    )


def make_gradient_background(size: int) -> Image.Image:
    img = Image.new('RGB', (size, size))
    draw = ImageDraw.Draw(img)
    top_color = (10, 132, 255)   # bleu iOS clair
    bot_color = (0, 64, 190)     # bleu profond
    for y in range(size):
        t = y / (size - 1)
        r = int(top_color[0] + (bot_color[0] - top_color[0]) * t)
        g = int(top_color[1] + (bot_color[1] - top_color[1]) * t)
        b = int(top_color[2] + (bot_color[2] - top_color[2]) * t)
        draw.line([(0, y), (size, y)], fill=(r, g, b))
    return img.convert('RGBA')


def make_shadow_layer(shape: Image.Image, size: int) -> Image.Image:
    """Crée un calque d'ombre portée à partir de la forme (RGBA)."""
    blur_radius = size * 0.015
    offset = int(size * 0.012)
    opacity = 0.45

    alpha = shape.split()[3].filter(ImageFilter.GaussianBlur(radius=blur_radius))
    alpha = alpha.point(lambda x: int(x * opacity))

    shifted = Image.new('L', (size, size), 0)
    shifted.paste(alpha, (offset, offset))

    shadow = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    shadow.putalpha(shifted)
    return shadow


def create_app_icon() -> Image.Image:
    big = SIZE * SCALE

    background = make_gradient_background(big)

    shape = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    draw_share_icon(ImageDraw.Draw(shape), big)

    shadow = make_shadow_layer(shape, big)

    composed = Image.alpha_composite(background, shadow)
    composed = Image.alpha_composite(composed, shape)

    return composed.convert('RGB').resize((SIZE, SIZE), Image.LANCZOS)


def main() -> None:
    print("Génération de l'icône de partage...")
    icon = create_app_icon()
    output_path = "AppIcon.png"
    icon.save(output_path, 'PNG', quality=100)
    print(f"Icône générée : {output_path} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
