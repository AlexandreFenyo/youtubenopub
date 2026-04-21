import SwiftUI

/// Vue de l'icône de l'application finale
/// Rectangle aux bords arrondis avec flèche vers un dossier
struct AppIconPreview: View {
    var body: some View {
        ZStack {
            // Fond avec dégradé bleu moderne
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.0, green: 0.48, blue: 1.0),
                    Color(red: 0.0, green: 0.35, blue: 0.85)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 35) {
                // Rectangle avec bords arrondis (document à partager)
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.white)
                        .frame(width: 280, height: 220)
                        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
                    
                    // Lignes pour simuler du contenu dans le document
                    VStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.4))
                            .frame(width: 200, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.4))
                            .frame(width: 180, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.4))
                            .frame(width: 190, height: 12)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.25))
                            .frame(width: 160, height: 12)
                    }
                }
                .offset(y: 30)
                
                // Flèche qui sort du rectangle et va vers le dossier
                ZStack {
                    // Trait de la flèche
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white)
                        .frame(width: 12, height: 80)
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                    
                    // Pointe de la flèche
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 60))
                        path.addLine(to: CGPoint(x: -35, y: 20))
                        path.addLine(to: CGPoint(x: 35, y: 20))
                        path.closeSubpath()
                    }
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                }
                .offset(y: 10)
                
                // Dossier de destination
                ZStack {
                    // Corps du dossier
                    RoundedRectangle(cornerRadius: 30)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 1.0, green: 0.85, blue: 0.2),
                                    Color(red: 1.0, green: 0.65, blue: 0.1)
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 320, height: 240)
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                    
                    // Onglet du dossier
                    RoundedRectangle(cornerRadius: 18)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color(red: 1.0, green: 0.8, blue: 0.15),
                                    Color(red: 1.0, green: 0.7, blue: 0.15)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 140, height: 45)
                        .offset(x: -70, y: -142)
                    
                    // Ligne de séparation de l'onglet
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: 280, height: 3)
                        .offset(y: -95)
                }
                .offset(y: -10)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Générateur d'icône - Permet de créer et sauvegarder l'icône
struct AppIconGenerator: View {
    @State private var generatedImage: UIImage?
    @State private var showingSaveConfirmation = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Générateur d'icône")
                .font(.title)
                .bold()
            
            // Prévisualisation de l'icône
            AppIconPreview()
                .scaleEffect(0.25)
                .frame(width: 256, height: 256)
                .background(Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 55))
                .overlay(
                    RoundedRectangle(cornerRadius: 55)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            Text("Taille : 1024x1024 pixels")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button(action: generateAndSaveIcon) {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("Générer et sauvegarder l'icône")
                }
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            
            if showingSaveConfirmation {
                Text("✓ Icône sauvegardée dans Photos!")
                    .foregroundColor(.green)
                    .bold()
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Instructions :")
                    .font(.headline)
                
                Group {
                    Text("1. Appuyez sur le bouton ci-dessus")
                    Text("2. Autorisez l'accès à Photos si demandé")
                    Text("3. L'icône sera sauvegardée (1024x1024px)")
                    Text("4. Dans Xcode, ouvrez Assets.xcassets")
                    Text("5. Sélectionnez AppIcon")
                    Text("6. Glissez l'image depuis Photos")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
    }
    
    @MainActor
    func generateAndSaveIcon() {
        let renderer = ImageRenderer(content: AppIconPreview())
        renderer.scale = 3.0 // Pour une meilleure qualité
        
        if let uiImage = renderer.uiImage {
            // Redimensionner à exactement 1024x1024
            let targetSize = CGSize(width: 1024, height: 1024)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            
            let resizedImage = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            
            generatedImage = resizedImage
            
            // Sauvegarder dans Photos
            UIImageWriteToSavedPhotosAlbum(resizedImage, nil, nil, nil)
            
            showingSaveConfirmation = true
            
            // Masquer la confirmation après 3 secondes
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                showingSaveConfirmation = false
            }
        }
    }
}


#Preview {
    AppIconGenerator()
}
