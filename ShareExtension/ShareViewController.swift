import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    let appGroup = "group.net.fenyo.apple.youtubenopub"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.0)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extractAndSaveURL()
    }

    private func extractAndSaveURL() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments else {
            complete()
            return
        }

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, _ in
                    var urlString: String?
                    if let url = data as? URL {
                        urlString = url.absoluteString
                    } else if let str = data as? String, URL(string: str) != nil {
                        urlString = str
                    }
                    if let urlString {
                        self?.save(urlString: self?.transform(urlString: urlString) ?? urlString)
                    }
                    DispatchQueue.main.async { self?.showCheckmark() }
                }
                return
            }
        }

        for attachment in attachments {
            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] data, _ in
                    var urlString: String?
                    if let str = data as? String, URL(string: str) != nil {
                        urlString = str
                    }
                    if let urlString {
                        self?.save(urlString: self?.transform(urlString: urlString) ?? urlString)
                    }
                    DispatchQueue.main.async { self?.showCheckmark() }
                }
                return
            }
        }

        complete()
    }

    private func transform(urlString: String) -> String {
        for prefix in ["https://www.youtube.com", "https://youtube.com"] {
            if urlString.hasPrefix(prefix) {
                return "https://www.yout-ube.com" + urlString.dropFirst(prefix.count)
            }
        }
        let shortPrefix = "https://youtu.be/"
        if urlString.hasPrefix(shortPrefix) {
            return "https://www.yout-ube.com/watch?v=\(urlString.dropFirst(shortPrefix.count))"
        }
        return urlString
    }

    private func save(urlString: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        var urls = defaults.stringArray(forKey: "sharedURLs") ?? []
        if !urls.contains(urlString) {
            urls.insert(urlString, at: 0)
        }
        defaults.set(urls, forKey: "sharedURLs")
    }

    private func showCheckmark() {
        let container = UIView()
        container.backgroundColor = UIColor.systemBackground
        container.layer.cornerRadius = 20
        container.layer.shadowColor = UIColor.black.cgColor
        container.layer.shadowOpacity = 0.15
        container.layer.shadowRadius = 12
        container.translatesAutoresizingMaskIntoConstraints = false

        let imageView = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        imageView.tintColor = .systemGreen
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "URL sauvegardée"
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(imageView)
        container.addSubview(label)
        view.addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 200),
            container.heightAnchor.constraint(equalToConstant: 100),

            imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            imageView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            imageView.widthAnchor.constraint(equalToConstant: 36),
            imageView.heightAnchor.constraint(equalToConstant: 36),

            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 8),
        ])

        container.alpha = 0
        UIView.animate(withDuration: 0.2) {
            container.alpha = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            UIView.animate(withDuration: 0.2, animations: {
                container.alpha = 0
            }) { _ in
                self?.complete()
            }
        }
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
