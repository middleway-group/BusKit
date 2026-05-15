import AppKit
import Foundation

// MARK: - UpdateChecker

final class UpdateChecker {
    static let shared = UpdateChecker()

    private let releasesURL = URL(string: "https://api.github.com/repos/pkarda/BusKit/releases/latest")!

    private init() {}

    func checkForUpdates(userInitiated: Bool = true) {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleResponse(data: data, response: response, error: error, userInitiated: userInitiated)
            }
        }.resume()
    }

    // MARK: - Private

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?, userInitiated: Bool) {
        if let error {
            if userInitiated {
                showError("Could not check for updates.\n\(error.localizedDescription)")
            }
            return
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            if userInitiated {
                showError("Received an unexpected response from the server.")
            }
            return
        }

        if let message = json["message"] as? String, message == "Not Found" {
            if userInitiated {
                showNoReleasesAvailable()
            }
            return
        }

        guard let tagName = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String
        else {
            if userInitiated {
                showError("Received an unexpected response from the server.")
            }
            return
        }

        let latestVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        if isNewerVersion(latestVersion, than: currentVersion) {
            showUpdateAvailable(latestVersion: latestVersion, releaseURL: htmlURL)
        } else if userInitiated {
            showUpToDate(currentVersion: currentVersion)
        }
    }

    private func isNewerVersion(_ latest: String, than current: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    private func showUpdateAvailable(latestVersion: String, releaseURL: String) {
        let alert = NSAlert()
        alert.messageText = "A new version of BusKit is available!"
        alert.informativeText = "BusKit \(latestVersion) is now available. Would you like to download it?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: releaseURL) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showUpToDate(currentVersion: String) {
        let alert = NSAlert()
        alert.messageText = "You're up-to-date!"
        alert.informativeText = "BusKit \(currentVersion) is currently the newest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showNoReleasesAvailable() {
        let alert = NSAlert()
        alert.messageText = "No Releases Available"
        alert.informativeText = "There are no releases published for BusKit yet."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
