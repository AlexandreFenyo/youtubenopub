import SwiftUI

/// Vue de l'icône de l'application finale
struct AppIconDesign: View {
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

/// Générateur d'icône avec fonctionnalités complètes
struct AppIconGenerator: View {
    @State private var generatedImage: UIImage?
    @State private var showingSaveConfirmation = false
    @State private var showingShareSheet = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 25) {
                Text("🎨 Générateur d'Icône")
                    .font(.largeTitle)
                    .bold()
                    .padding(.top)
                
                // Prévisualisation de l'icône
                AppIconDesign()
                    .scaleEffect(0.25)
                    .frame(width: 256, height: 256)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 55)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                    )
                    .shadow(radius: 5)
                
                Text("Icône 1024x1024 pixels")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Boutons d'action
                VStack(spacing: 15) {
                    Button(action: generateAndSaveIcon) {
                        HStack(spacing: 12) {
                            Image(systemName: "photo.on.rectangle")
                                .font(.title3)
                            Text("Sauvegarder dans Photos")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    
                    if let image = generatedImage {
                        Button(action: { showingShareSheet = true }) {
                            HStack(spacing: 12) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.title3)
                                Text("Partager l'icône")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .sheet(isPresented: $showingShareSheet) {
                            ShareSheet(items: [image])
                        }
                    }
                }
                .padding(.horizontal, 30)
                
                // Confirmation
                if showingSaveConfirmation {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Icône sauvegardée avec succès!")
                            .fontWeight(.medium)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .transition(.scale.combined(with: .opacity))
                }
                
                // Instructions
                VStack(alignment: .leading, spacing: 16) {
                    Text("📋 Instructions")
                        .font(.title3)
                        .bold()
                    
                    VStack(alignment: .leading, spacing: 12) {
                        InstructionRow(number: "1", text: "Appuyez sur 'Sauvegarder dans Photos'")
                        InstructionRow(number: "2", text: "Autorisez l'accès à Photos (si demandé)")
                        InstructionRow(number: "3", text: "Ouvrez Xcode sur votre Mac")
                        InstructionRow(number: "4", text: "Naviguez vers Assets.xcassets")
                        InstructionRow(number: "5", text: "Cliquez sur 'AppIcon'")
                        InstructionRow(number: "6", text: "Glissez l'image 1024x1024 depuis Photos")
                    }
                }
                .padding(20)
                .background(Color.blue.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 15))
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                Spacer(minLength: 30)
            }
            .padding(.bottom, 30)
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: showingSaveConfirmation)
    }
    
    @MainActor
    func generateAndSaveIcon() {
        let renderer = ImageRenderer(content: AppIconDesign())
        renderer.scale = 1.0 // Scale 1.0 pour avoir exactement 1024x1024
        
        if let uiImage = renderer.uiImage {
            generatedImage = uiImage
            
            // Sauvegarder dans Photos
            UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
            
            withAnimation {
                showingSaveConfirmation = true
            }
            
            // Générer une vibration de succès
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)
            
            // Masquer la confirmation après 3 secondes
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation {
                    showingSaveConfirmation = false
                }
            }
        }
    }
}

/// Ligne d'instruction avec numéro
struct InstructionRow: View {
    let number: String
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.blue)
                .clipShape(Circle())
            
            Text(text)
                .font(.callout)
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
}

/// Sheet de partage pour iOS
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    AppIconGenerator()
}
