#!/usr/bin/env python3
"""
Script pour générer l'icône de l'application
Nécessite: pip install pillow
"""

from PIL import Image, ImageDraw
import os

def create_app_icon():
    """Crée l'icône de l'application avec un rectangle, une flèche et un dossier"""
    
    # Taille de l'icône
    size = 1024
    
    # Créer l'image avec un fond bleu dégradé
    img = Image.new('RGB', (size, size))
    draw = ImageDraw.Draw(img)
    
    # Dessiner le dégradé bleu
    for y in range(size):
        # Gradient du bleu clair au bleu foncé
        r = int(0 + (0 * y / size))
        g = int(122 - (25 * y / size))
        b = int(255 - (38 * y / size))
        draw.line([(0, y), (size, y)], fill=(r, g, b))
    
    # Rectangle blanc aux bords arrondis (document à partager)
    rect_width, rect_height = 280, 220
    rect_x = (size - rect_width) // 2
    rect_y = 180
    draw.rounded_rectangle(
        [(rect_x, rect_y), (rect_x + rect_width, rect_y + rect_height)],
        radius=28,
        fill='white'
    )
    
    # Lignes bleues dans le rectangle (simulant du contenu)
    line_y = rect_y + 60
    for width in [200, 180, 190, 160]:
        line_x = (size - width) // 2
        draw.rounded_rectangle(
            [(line_x, line_y), (line_x + width, line_y + 12)],
            radius=4,
            fill=(100, 150, 255, 180)
        )
        line_y += 26
    
    # Flèche blanche vers le bas
    arrow_x = size // 2
    arrow_y_start = rect_y + rect_height + 20
    arrow_y_end = arrow_y_start + 80
    
    # Tige de la flèche
    draw.rounded_rectangle(
        [(arrow_x - 6, arrow_y_start), (arrow_x + 6, arrow_y_end)],
        radius=5,
        fill='white'
    )
    
    # Pointe de la flèche (triangle)
    arrow_tip = [
        (arrow_x, arrow_y_end + 30),  # Pointe
        (arrow_x - 35, arrow_y_end),   # Gauche
        (arrow_x + 35, arrow_y_end)    # Droite
    ]
    draw.polygon(arrow_tip, fill='white')
    
    # Dossier jaune/orange
    folder_width, folder_height = 320, 240
    folder_x = (size - folder_width) // 2
    folder_y = 650
    
    # Onglet du dossier
    tab_width, tab_height = 140, 45
    tab_x = folder_x + 20
    tab_y = folder_y - 20
    draw.rounded_rectangle(
        [(tab_x, tab_y), (tab_x + tab_width, tab_y + tab_height)],
        radius=18,
        fill=(255, 200, 40)
    )
    
    # Corps du dossier
    draw.rounded_rectangle(
        [(folder_x, folder_y), (folder_x + folder_width, folder_y + folder_height)],
        radius=30,
        fill=(255, 180, 30)
    )
    
    # Ligne de séparation sur le dossier
    draw.rounded_rectangle(
        [(folder_x + 20, folder_y + 25), (folder_x + folder_width - 20, folder_y + 28)],
        radius=2,
        fill=(255, 150, 30)
    )
    
    return img

def main():
    """Fonction principale"""
    print("🎨 Génération de l'icône de l'application...")
    
    # Créer l'icône
    icon = create_app_icon()
    
    # Sauvegarder l'icône
    output_path = "AppIcon.png"
    icon.save(output_path, 'PNG', quality=100)
    
    print(f"✅ Icône générée avec succès : {output_path}")
    print(f"   Taille : 1024x1024 pixels")
    print()
    print("📋 Prochaines étapes :")
    print("1. Ouvrez votre projet Xcode")
    print("2. Naviguez vers Assets.xcassets")
    print("3. Sélectionnez AppIcon")
    print("4. Glissez AppIcon.png dans l'emplacement 1024x1024")

if __name__ == "__main__":
    main()
